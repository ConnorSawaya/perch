// TOMLSnippetEditor.swift — reads a TOML file and changes single top-level keys, nothing else.
//
// Codex keeps its settings in `config.toml`. Perch needs to *read* a few facts from it (are hooks
// switched off? has the user trusted our hooks?) and, for one optional feature, to add or remove
// one top-level key. Pulling in a full TOML library is not an option (no dependencies), and
// re-printing someone's config would destroy their comments and layout.
//
// So this is deliberately not a TOML parser. It splits the file into lines, works out which
// lines are table headers, which are `key = value` statements (following values that span several
// lines) and which are comments, and keeps every line's original bytes. An edit replaces, inserts
// or deletes whole lines that belong to one key; every other byte of the file is written back
// exactly as it was read.
//
// If anything in the file does not fit that simple picture (`isFullyUnderstood == false`), reading
// still works on a best-effort basis but every edit throws instead of guessing.

import Foundation

struct TOMLSnippetEditor {

    /// One `key = value` statement.
    struct Entry: Equatable {
        /// Table the statement is in ([] for the top of the file) followed by the key's own parts.
        var path: [String]
        var firstLine: Int
        var lastLine: Int
        /// The value's text with comments removed, trimmed. Multi-line values are joined with "\n".
        var rawValue: String
    }

    struct Table: Equatable {
        var path: [String]
        var isArrayOfTables: Bool
        var line: Int
    }

    enum EditError: Error, LocalizedError, Equatable {
        case notUnderstood(line: Int)
        case keyIsATable(String)

        var errorDescription: String? {
            switch self {
            case .notUnderstood(let line):
                return "line \(line + 1) of the TOML file is in a form Perch does not understand, so the file was left alone."
            case .keyIsATable(let key):
                return "\"\(key)\" is written as a table in the TOML file, which Perch does not edit."
            }
        }
    }

    /// Every line with its line ending still attached (the last line may have none).
    private(set) var lines: [String]
    private(set) var entries: [Entry] = []
    private(set) var tables: [Table] = []
    /// Index of the first line Perch could not classify, if any.
    private(set) var firstProblemLine: Int?

    var isFullyUnderstood: Bool { firstProblemLine == nil }
    var text: String { lines.joined() }

    init(text: String) {
        lines = TOMLSnippetEditor.splitKeepingLineEndings(text)
        scan()
    }

    // MARK: Reading

    /// The raw value text at a full key path, e.g. `["features", "hooks"]`. The last definition wins.
    func rawValue(at path: [String]) -> String? {
        entries.last(where: { $0.path == path })?.rawValue
    }

    func bool(at path: [String]) -> Bool? {
        switch rawValue(at: path) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    func string(at path: [String]) -> String? {
        rawValue(at: path).flatMap(TOMLSnippetEditor.unquote)
    }

    /// A one-line array of strings such as `["python3", "/path/notify.py"]`. Nil for anything else.
    func stringArray(at path: [String]) -> [String]? {
        rawValue(at: path).flatMap(TOMLSnippetEditor.parseStringArray)
    }

    /// Paths of every table (and of every dotted key's parent) that starts with `prefix`.
    func tablePaths(under prefix: [String]) -> [[String]] {
        var seen: [[String]] = []
        let candidates = tables.map(\.path) + entries.map { Array($0.path.dropLast()) }
        for path in candidates where path.count > prefix.count && Array(path.prefix(prefix.count)) == prefix && !seen.contains(path) {
            seen.append(path)
        }
        return seen
    }

    // MARK: Editing (top-level keys only)

    /// Sets `key = rawValue` at the top of the file (before any table). Replaces the existing
    /// statement in place if there is one; otherwise adds one line after the last top-level key.
    mutating func setTopLevel(key: String, rawValue: String) throws {
        try requireEditable(key: key)
        let newLine = "\(key) = \(rawValue)"
        if let existing = entries.last(where: { $0.path == [key] }) {
            let ending = TOMLSnippetEditor.lineEnding(of: lines[existing.lastLine])
            lines.replaceSubrange(existing.firstLine...existing.lastLine, with: [newLine + ending])
        } else {
            let firstTableLine = tables.map(\.line).min() ?? lines.count
            let lastRootEntryLine = entries.filter { $0.lastLine < firstTableLine }.map(\.lastLine).max()
            let index = lastRootEntryLine.map { $0 + 1 } ?? firstInsertionLine(before: firstTableLine)
            insert(newLine, at: index)
        }
        scan()
    }

    /// Removes the top-level statement for `key`. Returns false when there is none.
    @discardableResult
    mutating func removeTopLevel(key: String) throws -> Bool {
        try requireEditable(key: key)
        guard let existing = entries.last(where: { $0.path == [key] }) else { return false }
        let removedLastLineOfFile = existing.lastLine == lines.count - 1
        let hadEnding = !TOMLSnippetEditor.lineEnding(of: lines[existing.lastLine]).isEmpty
        lines.removeSubrange(existing.firstLine...existing.lastLine)
        // If our line was the unterminated last line, the line before it was unterminated before we
        // were added: give it back its original shape so install + uninstall is byte-for-byte neutral.
        if removedLastLineOfFile, !hadEnding, let last = lines.indices.last {
            lines[last] = TOMLSnippetEditor.withoutLineEnding(lines[last])
        }
        scan()
        return true
    }

    private func requireEditable(key: String) throws {
        if let line = firstProblemLine { throw EditError.notUnderstood(line: line) }
        if tables.contains(where: { $0.path.first == key }) || entries.contains(where: { $0.path.count > 1 && $0.path.first == key }) {
            throw EditError.keyIsATable(key)
        }
    }

    /// Where a first top-level key goes when the file has none: after the opening comment block,
    /// before the first table.
    private func firstInsertionLine(before firstTableLine: Int) -> Int {
        var index = 0
        while index < firstTableLine, lines[index].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { index += 1 }
        // Comments directly above the first table describe that table: stay above them.
        return index == firstTableLine ? 0 : index
    }

    private mutating func insert(_ content: String, at index: Int) {
        let ending = lines.first.map(TOMLSnippetEditor.lineEnding).flatMap { $0.isEmpty ? nil : $0 } ?? "\n"
        if index >= lines.count {
            // Appending: terminate the current last line, and leave ours unterminated only if it was.
            if let last = lines.indices.last, TOMLSnippetEditor.lineEnding(of: lines[last]).isEmpty {
                lines[last] += ending
                lines.append(content)
            } else {
                lines.append(content + ending)
            }
        } else {
            lines.insert(content + ending, at: index)
        }
    }

    // MARK: Scanning

    private mutating func scan() {
        entries = []
        tables = []
        firstProblemLine = nil
        var currentTable: [String] = []
        var index = 0
        while index < lines.count {
            let line = TOMLSnippetEditor.withoutLineEnding(lines[index])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if trimmed.hasPrefix("[") {
                if let table = TOMLSnippetEditor.parseTableHeader(trimmed, line: index) {
                    tables.append(table)
                    currentTable = table.path
                } else {
                    noteProblem(index)
                }
                index += 1
                continue
            }
            guard let (key, valueStart) = TOMLSnippetEditor.splitKeyValue(line) else {
                noteProblem(index)
                index += 1
                continue
            }
            // Follow the value across lines until brackets and multi-line strings are closed.
            var state = ValueState()
            var pieces: [String] = []
            var last = index
            var remainder = valueStart
            while true {
                pieces.append(state.consume(remainder))
                // `key =` with nothing after it is not TOML; do not swallow the next line as its value.
                if !state.hasValue { break }
                if state.isComplete || last + 1 >= lines.count { break }
                last += 1
                remainder = TOMLSnippetEditor.withoutLineEnding(lines[last])
            }
            if !state.isComplete || state.sawGarbage { noteProblem(index) }
            let raw = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(path: currentTable + key, firstLine: index, lastLine: last, rawValue: raw))
            index = last + 1
        }
    }

    private mutating func noteProblem(_ line: Int) {
        if firstProblemLine == nil { firstProblemLine = line }
    }

    /// Tracks strings and brackets while a value is read, so `#` and `]` inside strings are not misread.
    private struct ValueState {
        private enum Mode { case plain, basic, literal, multiBasic, multiLiteral }
        private var mode = Mode.plain
        private var depth = 0
        private var sawValue = false
        private var ended = false
        var sawGarbage = false

        var hasValue: Bool { sawValue }
        var isComplete: Bool { mode == .plain && depth == 0 && sawValue }

        /// Consumes one line of value text and returns it without any trailing comment.
        mutating func consume(_ text: String) -> String {
            let chars = Array(text)
            var kept = ""
            var i = 0
            // A single-line string cannot continue on the next line.
            if mode == .basic || mode == .literal { sawGarbage = true; mode = .plain }
            while i < chars.count {
                let c = chars[i]
                func startsTriple(_ q: Character) -> Bool { i + 2 < chars.count && chars[i] == q && chars[i + 1] == q && chars[i + 2] == q }
                switch mode {
                case .plain:
                    if c == "#" { return kept }
                    if c == " " || c == "\t" { kept.append(c); i += 1; continue }
                    if ended && depth == 0 { sawGarbage = true }   // something after a finished value
                    sawValue = true
                    if startsTriple("\"") { mode = .multiBasic; kept += "\"\"\""; i += 3; continue }
                    if startsTriple("'") { mode = .multiLiteral; kept += "'''"; i += 3; continue }
                    if c == "\"" { mode = .basic } else if c == "'" { mode = .literal }
                    else if c == "[" || c == "{" { depth += 1 }
                    else if c == "]" || c == "}" { depth -= 1; if depth < 0 { sawGarbage = true; depth = 0 } }
                    if depth == 0, mode == .plain, c == "]" || c == "}" { ended = true }
                case .basic:
                    if c == "\\" { kept.append(c); i += 1; if i < chars.count { kept.append(chars[i]); i += 1 }; continue }
                    if c == "\"" { mode = .plain; ended = depth == 0 }
                case .literal:
                    if c == "'" { mode = .plain; ended = depth == 0 }
                case .multiBasic:
                    if c == "\\" { kept.append(c); i += 1; if i < chars.count { kept.append(chars[i]); i += 1 }; continue }
                    if startsTriple("\"") { mode = .plain; ended = depth == 0; kept += "\"\"\""; i += 3; continue }
                case .multiLiteral:
                    if startsTriple("'") { mode = .plain; ended = depth == 0; kept += "'''"; i += 3; continue }
                }
                kept.append(c)
                i += 1
            }
            if mode == .basic || mode == .literal { sawGarbage = true }   // unterminated one-line string
            return kept
        }
    }

    // MARK: Small parsers

    /// Splits `key = value` at the first `=` outside quotes. Returns the key's parts and the value text.
    private static func splitKeyValue(_ line: String) -> ([String], String)? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == "\\" && q == "\"" { index = line.index(after: index); if index == line.endIndex { return nil } }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "=" {
                guard let key = parseKeyPath(String(line[line.startIndex..<index])) else { return nil }
                return (key, String(line[line.index(after: index)...]))
            } else if c == "#" {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func parseTableHeader(_ trimmed: String, line: Int) -> Table? {
        // Drop a trailing comment, taking care not to cut inside a quoted key part.
        var header = ""
        var quote: Character?
        for c in trimmed {
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#" { break }
            header.append(c)
        }
        header = header.trimmingCharacters(in: .whitespaces)
        let isArray = header.hasPrefix("[[") && header.hasSuffix("]]")
        let strip = isArray ? 2 : 1
        guard header.hasPrefix("["), header.hasSuffix("]"), header.count > strip * 2,
              let path = parseKeyPath(String(header.dropFirst(strip).dropLast(strip))) else { return nil }
        return Table(path: path, isArrayOfTables: isArray, line: line)
    }

    /// `a.b."c.d"` → ["a", "b", "c.d"]. Nil when the text is not a valid dotted key.
    static func parseKeyPath(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var partWasQuoted = false
        var escaped = false
        func bareIsValid(_ s: String) -> Bool {
            !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        }
        func finish() -> Bool {
            let bare = current.trimmingCharacters(in: .whitespaces)
            if partWasQuoted { parts.append(current) } else if bareIsValid(bare) { parts.append(bare) } else { return false }
            current = ""
            partWasQuoted = false
            return true
        }
        for c in text {
            if let q = quote {
                if escaped { current.append(c); escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { quote = nil }
                else { current.append(c) }
            } else if c == "\"" || c == "'" {
                guard current.trimmingCharacters(in: .whitespaces).isEmpty, !partWasQuoted else { return nil }
                current = ""
                quote = c
                partWasQuoted = true
            } else if c == "." {
                guard finish() else { return nil }
            } else if partWasQuoted {
                guard c == " " || c == "\t" else { return nil }
            } else {
                current.append(c)
            }
        }
        guard quote == nil, finish() else { return nil }
        return parts
    }

    /// The text inside a one-line TOML string, with the common escapes resolved. Nil if `raw` is not one.
    static func unquote(_ raw: String) -> String? {
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'"), !raw.hasPrefix("'''") {
            return String(raw.dropFirst().dropLast())
        }
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\""), !raw.hasPrefix("\"\"\"") else { return nil }
        var out = ""
        var escaped = false
        for c in raw.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(c)   // \" and \\ (rarer escapes keep their letter)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return escaped ? nil : out
    }

    static func parseStringArray(_ raw: String) -> [String]? {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in raw.dropFirst().dropLast() {
            if let q = quote {
                current.append(c)
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q {
                    guard let value = unquote(current) else { return nil }
                    items.append(value)
                    current = ""
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                guard current.isEmpty else { return nil }
                quote = c
                current.append(c)
            } else if !(c == "," || c == " " || c == "\t" || c == "\n" || c == "\r") {
                return nil   // numbers, nested arrays...: not a plain string array
            }
        }
        return quote == nil ? items : nil
    }

    /// A TOML basic string literal for `text`.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\u%04X", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func quoteArray(_ items: [String]) -> String {
        "[" + items.map(quote).joined(separator: ", ") + "]"
    }

    // MARK: Lines

    private static func splitKeepingLineEndings(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        // Work on unicode scalars: Swift treats "\r\n" as one Character, which would hide the "\n".
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if scalar == "\n" { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func lineEnding(of line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        return line.hasSuffix("\n") ? "\n" : ""
    }

    private static func withoutLineEnding(_ line: String) -> String {
        // "\r\n" is a single Character in Swift, so either ending is dropped with one step.
        lineEnding(of: line).isEmpty ? line : String(line.dropLast())
    }
}
