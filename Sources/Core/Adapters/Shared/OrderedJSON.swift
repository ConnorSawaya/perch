// OrderedJSON.swift — JSON that remembers the order of object keys and the exact text of numbers.
//
// Perch edits config files that belong to other programs (Codex's hooks.json, Antigravity's
// hooks.json, Gemini CLI's settings.json). Foundation's JSON tools return dictionaries, which
// forget key order, so writing a file back would shuffle the user's keys. This small parser and
// printer keep every key where the user put it and reproduce numbers exactly as written, so the
// only difference after an edit is the part Perch changed (plus normalised indentation).
//
// It accepts strict JSON only. A file with comments or trailing commas fails to parse, and the
// installers then refuse to touch it rather than risk damaging it.

import Foundation

indirect enum OrderedJSON: Equatable {
    case null
    case bool(Bool)
    /// The number exactly as it was written (for example "5", "1.50", "1e3").
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    struct Member: Equatable {
        var key: String
        var value: OrderedJSON
    }

    // MARK: Reading

    /// Member lookup that never fails: a missing key or a non-object gives nil.
    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first(where: { $0.key == key })?.value
        }
        set {
            guard case .object(var members) = self else { return }
            let index = members.firstIndex(where: { $0.key == key })
            switch (index, newValue) {
            case (let i?, let value?): members[i].value = value          // replace in place: position is kept
            case (let i?, nil): members.remove(at: i)
            case (nil, let value?): members.append(Member(key: key, value: value))
            case (nil, nil): break
            }
            self = .object(members)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var arrayValue: [OrderedJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var members: [Member]? { if case .object(let m) = self { return m } else { return nil } }
    var isObject: Bool { members != nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    // MARK: Building

    /// Convenience for literals in the installers: `.object(["type": .string("command")])` keeps the given order.
    static func object(_ pairs: KeyValuePairs<String, OrderedJSON>) -> OrderedJSON {
        .object(pairs.map { Member(key: $0.key, value: $0.value) })
    }

    static func int(_ value: Int) -> OrderedJSON { .number(String(value)) }

    // MARK: Parsing

    enum ParseError: Error, Equatable {
        case invalid(offset: Int, reason: String)
    }

    /// Parses strict JSON text. A leading byte-order mark is allowed (Antigravity accepts one too).
    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipByteOrderMark()
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw parser.error("unexpected text after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        /// Deeply nested input is refused instead of overflowing the stack.
        static let maxDepth = 200

        var isAtEnd: Bool { position >= bytes.count }
        func error(_ reason: String) -> ParseError { .invalid(offset: position, reason: reason) }

        mutating func skipByteOrderMark() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { position = 3 }
        }

        mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < Parser.maxDepth else { throw error("nested too deeply") }
            guard position < bytes.count else { throw error("unexpected end of text") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func expect(_ word: String) throws {
            let wanted = Array(word.utf8)
            guard position + wanted.count <= bytes.count, Array(bytes[position..<position + wanted.count]) == wanted else {
                throw error("expected \(word)")
            }
            position += wanted.count
        }

        mutating func parseObject(depth: Int) throws -> OrderedJSON {
            position += 1
            var members: [Member] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
                position += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(Member(key: key, value: value))
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated object") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> OrderedJSON {
            position += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated array") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseNumber() throws -> String {
            let start = position
            let allowed = Set("+-0123456789.eE".utf8)
            while position < bytes.count, allowed.contains(bytes[position]) { position += 1 }
            let literal = String(decoding: bytes[start..<position], as: UTF8.self)
            // Double's parser accepts a few spellings JSON does not; those are rejected by hand.
            guard !literal.isEmpty, Double(literal) != nil, !literal.hasPrefix("+"), !literal.hasPrefix("."),
                  !literal.hasSuffix(".") else {
                position = start
                throw error("unexpected character")
            }
            return literal
        }

        mutating func parseString() throws -> String {
            position += 1   // opening quote
            var units: [UInt8] = []
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "\"") {
                    guard let text = String(validatingUTF8: units.map { CChar(bitPattern: $0) } + [0]) else {
                        throw error("string is not valid UTF-8")
                    }
                    return text
                }
                if byte < 0x20 { throw error("control character inside a string") }
                guard byte == UInt8(ascii: "\\") else { units.append(byte); continue }
                guard position < bytes.count else { break }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"): units.append(contentsOf: Array(String(try parseUnicodeEscape()).utf8))
                default: throw error("unknown escape")
                }
            }
            throw error("unterminated string")
        }

        /// Reads the four hex digits after `\u`, joining a surrogate pair into one character.
        mutating func parseUnicodeEscape() throws -> Character {
            let first = try parseHex4()
            if (0xD800...0xDBFF).contains(first) {
                guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else {
                    throw error("lone surrogate")
                }
                position += 2
                let second = try parseHex4()
                guard (0xDC00...0xDFFF).contains(second) else { throw error("invalid surrogate pair") }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw error("invalid character") }
                return Character(scalar)
            }
            guard let scalar = Unicode.Scalar(first) else { throw error("lone surrogate") }
            return Character(scalar)
        }

        mutating func parseHex4() throws -> UInt32 {
            guard position + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid \\u escape")
            }
            position += 4
            return value
        }
    }

    // MARK: Printing

    /// JSON text with two-space indentation and a final newline, keys in their stored order.
    func serialized() -> String {
        var out = ""
        write(into: &out, indent: 0)
        out += "\n"
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closingPad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let s): out += OrderedJSON.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += closingPad + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += pad + OrderedJSON.quote(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += closingPad + "}"
        }
    }

    /// A JSON string literal. Only what JSON requires is escaped, so paths keep their plain slashes.
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
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Conversion

    /// The same data as the app-wide `JSONValue` (key order is lost, which is fine for reading).
    var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let literal): return .number(Double(literal) ?? 0)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(\.jsonValue))
        case .object(let members):
            return .object(Dictionary(members.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { _, last in last }))
        }
    }
}
