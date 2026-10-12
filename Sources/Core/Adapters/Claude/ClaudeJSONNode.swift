// ClaudeJSONNode.swift — JSON that can be written back exactly as it was read.
//
// Perch edits a file that belongs to the user: Claude Code's settings.json. The app's general
// JSONValue type is fine for reading, but writing with it would reorder every object's keys and
// reformat numbers and string escapes. This type keeps what JSONValue throws away — the order of
// keys and the exact source text of every number, string and key — so the parts of the file we
// do not own come out byte for byte the same.
//
// The parser is strict (standard JSON only). Claude Code's settings file is plain JSON, and a
// file we cannot read with certainty is a file we must not rewrite.

import Foundation

/// One member of a JSON object: `"key": value`.
struct ClaudeJSONMember {
    var key: String
    /// The key exactly as written in the file, quotes included. Nil for keys we create.
    var rawKey: String?
    var value: ClaudeJSONNode

    init(_ key: String, _ value: ClaudeJSONNode, rawKey: String? = nil) {
        self.key = key
        self.value = value
        self.rawKey = rawKey
    }
}

indirect enum ClaudeJSONNode {
    case null
    case bool(Bool)
    /// The number's source text ("86400", "1.50", "1e3"), never converted.
    case number(String)
    /// The decoded text, plus the literal as written in the file (quotes included) when it came from one.
    case string(String, raw: String?)
    case array([ClaudeJSONNode])
    case object([ClaudeJSONMember])

    // MARK: Building

    static func text(_ value: String) -> ClaudeJSONNode { .string(value, raw: nil) }
    static func integer(_ value: Int) -> ClaudeJSONNode { .number(String(value)) }

    // MARK: Reading

    var stringValue: String? { if case .string(let value, _) = self { return value } else { return nil } }
    var elements: [ClaudeJSONNode]? { if case .array(let items) = self { return items } else { return nil } }
    var members: [ClaudeJSONMember]? { if case .object(let members) = self { return members } else { return nil } }

    /// The value of a key in an object. When a key is written twice the last one counts, as it
    /// does for every JSON reader.
    subscript(key: String) -> ClaudeJSONNode? { members?.last { $0.key == key }?.value }

    /// The same data as the app's everyday JSON type (key order and number spelling are lost).
    var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let text): return Double(text).map(JSONValue.number) ?? .null
        case .string(let value, _): return .string(value)
        case .array(let items): return .array(items.map(\.jsonValue))
        case .object(let members):
            return .object(Dictionary(members.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { _, last in last }))
        }
    }

    /// True when both hold the same data in the same order. How it was spelled in the file
    /// (escapes, "1.0" against "1") does not matter.
    func isSame(as other: ClaudeJSONNode) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b || (Double(a) != nil && Double(a) == Double(b))
        case (.string(let a, _), .string(let b, _)): return a == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isSame(as: $1) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value.isSame(as: $1.value) }
        default: return false
        }
    }

    // MARK: Writing

    /// JSON text for this value.
    /// - `indent`: one level of indentation ("  "); nil writes everything on one line.
    /// - `level`: how deep this value already sits, so that its inner lines line up with the file.
    func serialized(indent: String?, newline: String = "\n", level: Int = 0) -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let text): return text
        case .string(let value, let raw): return raw ?? Self.quote(value)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let parts = items.map { $0.serialized(indent: indent, newline: newline, level: level + 1) }
            return Self.wrap(parts, open: "[", close: "]", indent: indent, newline: newline, level: level)
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let separator = indent == nil ? ":" : ": "
            let parts = members.map {
                ($0.rawKey ?? Self.quote($0.key)) + separator + $0.value.serialized(indent: indent, newline: newline, level: level + 1)
            }
            return Self.wrap(parts, open: "{", close: "}", indent: indent, newline: newline, level: level)
        }
    }

    private static func wrap(_ parts: [String], open: String, close: String, indent: String?, newline: String, level: Int) -> String {
        guard let indent else { return open + parts.joined(separator: ",") + close }
        let inner = String(repeating: indent, count: level + 1)
        let outer = String(repeating: indent, count: level)
        return open + newline + parts.map { inner + $0 }.joined(separator: "," + newline) + newline + outer + close
    }

    /// A JSON string literal. Only what JSON requires is escaped, so paths stay readable.
    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// Why a piece of text is not JSON, and where.
struct ClaudeJSONError: Error, Equatable {
    var message: String
    /// Byte offset into the text.
    var offset: Int
}

/// A strict JSON parser over UTF-8 bytes that also reports where each top-level member sits.
struct ClaudeJSONParser {
    /// Where one member of the outermost object is in the text (byte offsets; ends are exclusive).
    struct Span: Equatable {
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    struct Result {
        var root: ClaudeJSONNode
        /// One span per member when the root is an object, in order; empty otherwise.
        var spans: [Span]
        /// Offsets of the root value's first and last byte.
        var rootStart: Int
        var rootEnd: Int
    }

    private let bytes: [UInt8]
    private var position = 0
    private var spans: [Span] = []
    /// Deeper nesting than this is refused rather than risking the stack.
    private static let maxDepth = 200

    static func parse(_ bytes: [UInt8]) throws -> Result {
        var parser = ClaudeJSONParser(bytes: bytes)
        // A byte-order mark is not JSON, but editors add one; it is skipped and left in place.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.position = 3 }
        parser.skipWhitespace()
        let start = parser.position
        let root = try parser.value(depth: 0)
        let end = parser.position
        parser.skipWhitespace()
        guard parser.position == bytes.count else { throw parser.unexpected("unexpected text after the end of the JSON value") }
        return Result(root: root, spans: parser.spans, rootStart: start, rootEnd: end - 1)
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func failure(_ message: String) -> ClaudeJSONError { ClaudeJSONError(message: message, offset: position) }

    /// The error for "something else was expected here", naming the two most common causes
    /// (a file that stops early, a comment) in words the user can act on.
    private func unexpected(_ message: String) -> ClaudeJSONError {
        guard let byte = current else { return failure("unexpected end of file") }
        return failure(byte == UInt8(ascii: "/") ? "comments are not allowed in JSON" : message)
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { position += 1 }
    }

    private mutating func value(depth: Int) throws -> ClaudeJSONNode {
        guard depth <= Self.maxDepth else { throw failure("nested too deeply") }
        guard let byte = current else { throw unexpected("") }
        switch byte {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""):
            let (text, raw) = try string()
            return .string(text, raw: raw)
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw unexpected("unexpected character")
        }
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else {
            throw failure("unexpected word")
        }
        position += expected.count
    }

    private mutating func object(depth: Int) throws -> ClaudeJSONNode {
        position += 1
        var members: [ClaudeJSONMember] = []
        skipWhitespace()
        if current == UInt8(ascii: "}") { position += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else {
                throw unexpected(current == UInt8(ascii: "}") ? "a comma before } is not allowed in JSON" : "expected a key in double quotes")
            }
            let keyStart = position
            let (key, rawKey) = try string()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw unexpected("expected : after a key") }
            position += 1
            skipWhitespace()
            let valueStart = position
            let value = try self.value(depth: depth + 1)
            if depth == 0 { spans.append(Span(keyStart: keyStart, valueStart: valueStart, valueEnd: position)) }
            members.append(ClaudeJSONMember(key, value, rawKey: rawKey))
            skipWhitespace()
            if current == UInt8(ascii: ",") { position += 1; continue }
            if current == UInt8(ascii: "}") { position += 1; return .object(members) }
            throw unexpected("expected , or } in an object")
        }
    }

    private mutating func array(depth: Int) throws -> ClaudeJSONNode {
        position += 1
        var items: [ClaudeJSONNode] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { position += 1; return .array(items) }
        while true {
            skipWhitespace()
            if current == UInt8(ascii: "]") { throw failure("a comma before ] is not allowed in JSON") }
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            if current == UInt8(ascii: ",") { position += 1; continue }
            if current == UInt8(ascii: "]") { position += 1; return .array(items) }
            throw unexpected("expected , or ] in an array")
        }
    }

    private mutating func number() throws -> String {
        let start = position
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } ?? false }
        if current == UInt8(ascii: "-") { position += 1 }
        guard isDigit(current) else { throw failure("malformed number") }
        if current == UInt8(ascii: "0") { position += 1 } else { while isDigit(current) { position += 1 } }
        if current == UInt8(ascii: ".") {
            position += 1
            guard isDigit(current) else { throw failure("malformed number") }
            while isDigit(current) { position += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            position += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
            guard isDigit(current) else { throw failure("malformed number") }
            while isDigit(current) { position += 1 }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// Reads a string literal and returns its decoded text and its exact source text.
    private mutating func string() throws -> (String, String) {
        let start = position
        position += 1
        var decoded: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("a string is missing its closing quote") }
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                let raw = String(decoding: bytes[start..<position], as: UTF8.self)
                return (String(decoding: decoded, as: UTF8.self), raw)
            case UInt8(ascii: "\\"):
                guard let escape = current else { throw failure("unfinished escape in a string") }
                position += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(escape)
                case UInt8(ascii: "b"): decoded.append(0x08)
                case UInt8(ascii: "f"): decoded.append(0x0C)
                case UInt8(ascii: "n"): decoded.append(0x0A)
                case UInt8(ascii: "r"): decoded.append(0x0D)
                case UInt8(ascii: "t"): decoded.append(0x09)
                case UInt8(ascii: "u"): decoded.append(contentsOf: Array(String(try unicodeEscape()).utf8))
                default: throw failure("unknown escape in a string")
                }
            case 0..<0x20:
                throw failure("a line break or control character inside a string")
            default:
                decoded.append(byte)
            }
        }
    }

    /// Reads the four hex digits after `\u` (and a following low surrogate when needed).
    private mutating func unicodeEscape() throws -> Character {
        func unit() throws -> UInt32 {
            guard position + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16) else {
                throw failure("malformed \\u escape in a string")
            }
            return value
        }
        let first = try unit()
        position += 4
        var scalarValue = first
        if (0xD800...0xDBFF).contains(first) {
            // A character outside the basic plane is written as two escapes in a row.
            guard position + 6 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else {
                throw failure("half of a two-part \\u escape is missing")
            }
            position += 2
            let second = try unit()
            position += 4
            guard (0xDC00...0xDFFF).contains(second) else { throw failure("malformed two-part \\u escape") }
            scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(scalarValue) else { throw failure("malformed \\u escape in a string") }
        return Character(scalar)
    }
}
