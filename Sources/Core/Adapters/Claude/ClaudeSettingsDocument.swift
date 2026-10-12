// ClaudeSettingsDocument.swift — changes one top-level key of settings.json and nothing else.
//
// Claude Code's settings.json holds the user's permissions, environment, plugins, and other
// tools' hooks. Perch owns exactly two keys in it, "hooks" (partly) and "statusLine". Instead of
// decoding the whole file and writing it out again — which reorders keys and reformats values —
// this type replaces only the bytes of the one value being changed and leaves every other byte
// of the file as the user (or Claude Code) wrote it.
//
// Every change is checked before it is accepted: the result must still be valid JSON, the changed
// key must hold what was intended, and every other key must hold exactly what it held before.

import Foundation

/// Reasons Perch refuses to install into, or cannot read, a settings file.
enum ClaudeInstallError: Error, LocalizedError, Equatable {
    /// The file is not strict JSON (a comment, a trailing comma, a typo...).
    case notJSON(path: String, line: Int, reason: String)
    /// Valid JSON, but not shaped like a settings file where it matters to us.
    case unexpectedShape(path: String, problem: String)
    case unreadable(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    /// An edit did not survive its own safety check (a bug in Perch, never the user's fault).
    case editFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .notJSON(let path, let line, let reason):
            return "Perch did not change \(path) because it is not valid JSON (line \(line): \(reason)). "
                + "Fix the file, or remove the problem line, and try again."
        case .unexpectedShape(let path, let problem):
            return "Perch did not change \(path) because \(problem). Nothing was modified."
        case .unreadable(let path, let reason):
            return "Perch could not read \(path): \(reason)."
        case .writeFailed(let path, let reason):
            return "Perch could not write \(path): \(reason). The file was left as it was."
        case .editFailed(let path):
            return "Perch could not edit \(path) safely, so it left the file untouched."
        }
    }
}

struct ClaudeSettingsDocument {
    /// The whole file as text.
    private(set) var text: String
    /// Used in error messages only.
    let path: String
    private var bytes: [UInt8]
    private var members: [ClaudeJSONMember]
    private var spans: [ClaudeJSONParser.Span]
    private var openBrace: Int
    private var closeBrace: Int

    /// The line break the file uses.
    private var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// - Parameter text: the file's contents. An empty (or all-whitespace) file counts as `{}`.
    init(text: String, path: String) throws {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : text
        let bytes = Array(source.utf8)
        let parsed: ClaudeJSONParser.Result
        do {
            parsed = try ClaudeJSONParser.parse(bytes)
        } catch let error as ClaudeJSONError {
            let line = bytes.prefix(min(error.offset, bytes.count)).filter { $0 == 0x0A }.count + 1
            throw ClaudeInstallError.notJSON(path: path, line: line, reason: error.message)
        }
        guard case .object(let members) = parsed.root else {
            throw ClaudeInstallError.unexpectedShape(path: path, problem: "it does not contain a JSON object at the top level")
        }
        self.text = source
        self.path = path
        self.bytes = bytes
        self.members = members
        self.spans = parsed.spans
        self.openBrace = parsed.rootStart
        self.closeBrace = parsed.rootEnd
    }

    // MARK: - Reading

    var keys: [String] { members.map(\.key) }
    var isEmpty: Bool { members.isEmpty }

    func node(_ key: String) -> ClaudeJSONNode? { members.last { $0.key == key }?.value }

    /// The value of a key exactly as it is written in the file.
    func rawText(_ key: String) -> String? {
        guard let index = members.lastIndex(where: { $0.key == key }) else { return nil }
        return String(decoding: bytes[spans[index].valueStart..<spans[index].valueEnd], as: UTF8.self)
    }

    // MARK: - Changing

    /// Sets a top-level key, in place when it exists and as a new last member when it does not.
    mutating func set(_ key: String, to node: ClaudeJSONNode) throws {
        let layout = self.layout
        try replaceValue(key, with: node.serialized(indent: layout.unit, newline: newline, level: layout.unit == nil ? 0 : 1),
                         expecting: node)
    }

    /// Like `set`, with the value given as JSON text that is inserted exactly as it is (used to
    /// put back a value that was saved earlier).
    mutating func setRaw(_ key: String, text valueText: String) throws {
        guard let parsed = try? ClaudeJSONParser.parse(Array(valueText.utf8)) else { throw ClaudeInstallError.editFailed(path: path) }
        try replaceValue(key, with: valueText.trimmingCharacters(in: .whitespacesAndNewlines), expecting: parsed.root)
    }

    /// Removes a top-level key together with its comma. Does nothing when the key is absent.
    mutating func remove(_ key: String) throws {
        while let index = members.lastIndex(where: { $0.key == key }) {
            var edited = bytes
            if members.count == 1 {
                edited.removeSubrange((openBrace + 1)..<closeBrace)
            } else if index == members.count - 1 {
                edited.removeSubrange(spans[index - 1].valueEnd..<spans[index].valueEnd)
            } else {
                edited.removeSubrange(spans[index].keyStart..<spans[index + 1].keyStart)
            }
            var expected = members
            expected.remove(at: index)
            try accept(edited, expecting: expected)
        }
    }

    // MARK: - Internals

    /// How the file is laid out: what stands before each top-level key, and one level of indentation.
    /// `unit` is nil when the whole object is written on a single line.
    private var layout: (memberPrefix: String, unit: String?) {
        guard let first = spans.first else { return ("  ", "  ") }
        let gap = String(decoding: bytes[(openBrace + 1)..<first.keyStart], as: UTF8.self)
        guard let lineBreak = gap.lastIndex(where: { $0.isNewline }) else { return ("", nil) }
        let prefix = String(gap[gap.index(after: lineBreak)...])
        return (prefix, prefix.isEmpty ? "  " : prefix)
    }

    private mutating func replaceValue(_ key: String, with valueText: String, expecting node: ClaudeJSONNode) throws {
        var edited = bytes
        var expected = members
        let layout = self.layout
        if let index = members.lastIndex(where: { $0.key == key }) {
            edited.replaceSubrange(spans[index].valueStart..<spans[index].valueEnd, with: Array(valueText.utf8))
            expected[index].value = node
        } else {
            let member = ClaudeJSONNode.quote(key) + ": " + valueText
            if let last = spans.last {
                let separator = layout.unit == nil ? ", " : "," + newline + layout.memberPrefix
                edited.insert(contentsOf: Array((separator + member).utf8), at: last.valueEnd)
            } else {
                let inside = newline + layout.memberPrefix + member + newline
                edited.replaceSubrange((openBrace + 1)..<closeBrace, with: Array(inside.utf8))
            }
            expected.append(ClaudeJSONMember(key, node))
        }
        try accept(edited, expecting: expected)
    }

    /// Adopts the edited text only if it parses and holds exactly the expected members.
    private mutating func accept(_ edited: [UInt8], expecting expected: [ClaudeJSONMember]) throws {
        guard let editedText = String(bytes: edited, encoding: .utf8),
              let result = try? ClaudeSettingsDocument(text: editedText, path: path),
              ClaudeJSONNode.object(result.members).isSame(as: .object(expected)) else {
            throw ClaudeInstallError.editFailed(path: path)
        }
        self = result
    }
}
