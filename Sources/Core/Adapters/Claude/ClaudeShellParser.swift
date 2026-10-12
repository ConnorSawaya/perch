// ClaudeShellParser.swift — reads a shell command line well enough to see what it will run.
//
// The "this looks risky" check on approval cards (ClaudeDangerDetector) must tell
// `rm -rf build` from `echo "rm -rf build"`. Searching the text for scary words cannot do that,
// so this file splits a command line the way a shell would: into pipelines of simple commands,
// each a list of words with the quotes removed. It also collects what sits inside `$(...)`,
// backticks and `<(...)` (those are commands too) and the bodies of here-documents.
//
// It is deliberately a reader, not a shell: nothing is expanded or executed, and anything it
// does not understand is kept as ordinary text.

import Foundation

/// One simple command: `FOO=1 rm -rf build > log.txt` has three words and one redirect.
struct ClaudeShellCommand: Equatable {
    struct Redirect: Equatable {
        var op: String
        var target: String
    }

    /// Words in order, quotes and backslashes already removed.
    var words: [String] = []
    var redirects: [Redirect] = []
    /// The text inside every `$(...)`, backtick pair and `<(...)` that appears in this command.
    var nested: [String] = []
    /// The body of a here-document (`<<EOF`) attached to this command.
    var heredoc: String?
    /// Here-document end markers seen on the command line, waiting for their bodies.
    fileprivate var heredocDelimiters: [String] = []

    fileprivate var isEmpty: Bool {
        words.isEmpty && redirects.isEmpty && nested.isEmpty && heredocDelimiters.isEmpty
    }

    init(words: [String] = []) { self.words = words }
}

enum ClaudeShellParser {
    /// Splits a command line into pipelines (separated by `;`, `&&`, `||`, `&`, line breaks and
    /// parentheses); each pipeline is the list of commands joined by `|`.
    static func pipelines(in text: String) -> [[ClaudeShellCommand]] {
        var lexer = Lexer(chars: Array(text.replacingOccurrences(of: "\r\n", with: "\n")))
        lexer.run()
        var result: [[ClaudeShellCommand]] = []
        var lastPipeline = -1
        for (command, pipeline) in zip(lexer.commands, lexer.pipelineOf) {
            if pipeline == lastPipeline, !result.isEmpty {
                result[result.count - 1].append(command)
            } else {
                result.append([command])
                lastPipeline = pipeline
            }
        }
        return result
    }

    private struct Lexer {
        let chars: [Character]
        var i = 0
        var word = ""
        /// True once a word has started, even if it is still empty (as in `''`).
        var inWord = false
        var command = ClaudeShellCommand()
        var commands: [ClaudeShellCommand] = []
        /// For each entry of `commands`, the number of the pipeline it belongs to.
        var pipelineOf: [Int] = []
        var pipelineNumber = 0
        /// A redirect operator whose target word has not been read yet.
        var pendingRedirect: String?
        /// Index into `commands` of the first command on the current line (for here-documents).
        var lineStart = 0

        func peek(_ offset: Int) -> Character? {
            let index = i + offset
            return index < chars.count ? chars[index] : nil
        }

        mutating func run() {
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "\\":
                    // A backslash makes the next character ordinary; before a line break it joins two lines.
                    if let next = peek(1), next != "\n" { word.append(next); inWord = true }
                    i += 2
                case "'":
                    inWord = true
                    i += 1
                    while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                    i += 1
                case "\"":
                    readDoubleQuoted()
                case "`":
                    let inner = readBackticks()
                    command.nested.append(inner)
                    word += inner
                    inWord = true
                case "$" where peek(1) == "(":
                    i += 2
                    let inner = readBalanced(open: "(", close: ")")
                    command.nested.append(inner)
                    word += "$(" + inner + ")"
                    inWord = true
                case "$" where peek(1) == "{":
                    i += 2
                    word += "${" + readBalanced(open: "{", close: "}") + "}"
                    inWord = true
                case "#" where !inWord:
                    while i < chars.count, chars[i] != "\n" { i += 1 }   // a comment runs to the end of the line
                case " ", "\t":
                    endWord()
                    i += 1
                case "\n":
                    i += 1
                    endPipeline()
                    readHeredocBodies()
                    lineStart = commands.count
                case ";":
                    endPipeline()
                    i += 1
                case "&":
                    if peek(1) == "&" {
                        endPipeline()
                        i += 2
                    } else if peek(1) == ">" {
                        // "&> file" sends both outputs to a file.
                        endWord()
                        i += peek(2) == ">" ? 3 : 2
                        pendingRedirect = ">"
                    } else {
                        endPipeline()
                        i += 1
                    }
                case "|":
                    if peek(1) == "|" {
                        endPipeline()
                        i += 2
                    } else {
                        endCommand()
                        i += peek(1) == "&" ? 2 : 1
                    }
                case "(", ")":
                    endPipeline()
                    i += 1
                case "<", ">":
                    if peek(1) == "(" {
                        // Process substitution: the output (or input) of a command used as a file.
                        i += 2
                        let inner = readBalanced(open: "(", close: ")")
                        command.nested.append(inner)
                        word += String(c) + "(" + inner + ")"
                        inWord = true
                    } else {
                        readRedirect()
                    }
                default:
                    word.append(c)
                    inWord = true
                    i += 1
                }
            }
            endPipeline()
        }

        // MARK: Ending words, commands and pipelines

        mutating func endWord() {
            guard inWord else { return }
            if let op = pendingRedirect {
                pendingRedirect = nil
                if op == "<<" || op == "<<-" {
                    command.heredocDelimiters.append(word)
                } else {
                    command.redirects.append(.init(op: op, target: word))
                }
            } else {
                command.words.append(word)
            }
            word = ""
            inWord = false
        }

        mutating func endCommand() {
            endWord()
            pendingRedirect = nil
            if !command.isEmpty {
                commands.append(command)
                pipelineOf.append(pipelineNumber)
            }
            command = ClaudeShellCommand()
        }

        mutating func endPipeline() {
            endCommand()
            pipelineNumber += 1
        }

        // MARK: Quotes, substitutions, redirects

        mutating func readDoubleQuoted() {
            inWord = true
            i += 1
            while i < chars.count, chars[i] != "\"" {
                let c = chars[i]
                if c == "\\", let next = peek(1) {
                    // Inside double quotes a backslash only escapes these few characters.
                    if "\"\\$`".contains(next) { word.append(next) } else if next != "\n" { word.append(c); word.append(next) }
                    i += 2
                } else if c == "$", peek(1) == "(" {
                    i += 2
                    let inner = readBalanced(open: "(", close: ")")
                    command.nested.append(inner)
                    word += "$(" + inner + ")"
                } else if c == "`" {
                    let inner = readBackticks()
                    command.nested.append(inner)
                    word += inner
                } else {
                    word.append(c)
                    i += 1
                }
            }
            i += 1
        }

        /// Reads from an opening backtick to its partner and returns what is between them.
        mutating func readBackticks() -> String {
            var inner = ""
            i += 1
            while i < chars.count, chars[i] != "`" {
                if chars[i] == "\\", let next = peek(1) { inner.append(next); i += 2 } else { inner.append(chars[i]); i += 1 }
            }
            i += 1
            return inner
        }

        /// Reads up to the bracket that closes one already opened (`i` is just past the opener),
        /// skipping over quoted text, and returns what is inside.
        mutating func readBalanced(open: Character, close: Character) -> String {
            var inner = ""
            var depth = 1
            while i < chars.count {
                let c = chars[i]
                if c == "\\", let next = peek(1) {
                    inner.append(c); inner.append(next); i += 2
                    continue
                }
                if c == "'" || c == "\"" {
                    inner.append(c); i += 1
                    while i < chars.count, chars[i] != c {
                        if c == "\"", chars[i] == "\\", let next = peek(1) { inner.append(chars[i]); inner.append(next); i += 2; continue }
                        inner.append(chars[i]); i += 1
                    }
                    if i < chars.count { inner.append(c); i += 1 }
                    continue
                }
                if c == open { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 { i += 1; return inner }
                }
                inner.append(c)
                i += 1
            }
            return inner
        }

        mutating func readRedirect() {
            // A number stuck to the operator ("2>") names a file descriptor; it is not an argument.
            if inWord, !word.isEmpty, word.allSatisfy(\.isNumber) { word = ""; inWord = false } else { endWord() }
            let first = chars[i]
            var op = String(first)
            i += 1
            if let second = peek(0), (first == ">" && ">&|".contains(second)) || (first == "<" && "<&>".contains(second)) {
                op.append(second)
                i += 1
                if op == "<<", let third = peek(0), third == "<" || third == "-" {
                    op.append(third)
                    i += 1
                }
            }
            pendingRedirect = op
        }

        /// After a line that announced here-documents, reads their bodies (the following lines up
        /// to each end marker) and attaches them to the commands that asked for them.
        mutating func readHeredocBodies() {
            for index in lineStart..<commands.count where !commands[index].heredocDelimiters.isEmpty {
                for delimiter in commands[index].heredocDelimiters {
                    var body: [String] = []
                    while i < chars.count {
                        var line = ""
                        while i < chars.count, chars[i] != "\n" { line.append(chars[i]); i += 1 }
                        i += 1
                        if line.trimmingCharacters(in: .whitespaces) == delimiter { break }
                        body.append(line)
                    }
                    let text = body.joined(separator: "\n")
                    commands[index].heredoc = commands[index].heredoc.map { $0 + "\n" + text } ?? text
                }
                commands[index].heredocDelimiters = []
            }
        }
    }
}
