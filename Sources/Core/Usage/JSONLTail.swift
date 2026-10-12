// JSONLTail.swift — reads only the NEW complete lines of a growing ".jsonl" file.
//
// Agents append one JSON object per line to their session files while they work. Perch reads
// those files again and again, so each read must be cheap: remember how far the last read got
// (a FileCursor), continue from there, and never load a whole file into memory.
//
// Rules this file implements (docs/research/claude-usage.md, section 9):
//   • A last line without a newline is still being written: leave it for next time.
//   • If the file is shorter than the remembered position, was replaced by another file, or the
//     bytes just before that position changed, it was rewritten: start again from byte 0.
//     (Starting again is always safe because the ledger de-duplicates.)
//   • Read in 1 MB pieces; a single line may grow the buffer up to 32 MB, beyond that it is skipped.
// Files are opened read-only and never written.

import Foundation

/// How far a file has been read, plus enough about the file to notice that it changed.
struct FileCursor: Equatable {
    var inode: UInt64 = 0
    var device: Int64 = 0
    /// Size and modification time when the file was last read. Both unchanged = nothing new.
    var size: Int64 = 0
    var mtimeMs: Int64 = 0
    /// First byte not yet consumed. Always just after a newline (or 0).
    var offset: Int64 = 0
    /// Hash of the 64 bytes before `offset`; a mismatch means the file was rewritten.
    var tailHash: UInt64 = 0
}

final class JSONLTail {
    enum Opening {
        /// Same size and modification time as last time: nothing to do.
        case unchanged
        /// Missing, not a regular file, or not readable.
        case unreadable
        case ready(JSONLTail)
    }

    static let chunkBytes = 1 << 20
    static let maxLineBytes = 32 << 20
    private static let tailBytes = 64

    /// True when reading starts from byte 0 although an earlier read had got further
    /// (the file was truncated, replaced or rewritten). Readers that keep running totals reset them.
    let startsOver: Bool
    /// When the file was created, in milliseconds since 1970.
    let birthMs: Int64
    /// The position to remember for next time. Final once `forEachLine` has returned.
    private(set) var cursor: FileCursor
    /// Lines longer than `maxLineBytes` that were skipped.
    private(set) var oversizedLines = 0

    private let descriptor: Int32

    private init(descriptor: Int32, cursor: FileCursor, startsOver: Bool, birthMs: Int64) {
        self.descriptor = descriptor
        self.cursor = cursor
        self.startsOver = startsOver
        self.birthMs = birthMs
    }

    deinit { Darwin.close(descriptor) }

    /// Opens `path` for reading whatever was appended since `cursor`.
    static func open(path: String, cursor: FileCursor) -> Opening {
        // O_NONBLOCK: opening something that is not a regular file (a named pipe) must not hang the scan.
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return .unreadable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            return .unreadable
        }
        let inode = UInt64(info.st_ino)
        let device = Int64(info.st_dev)
        let size = Int64(info.st_size)
        let mtimeMs = milliseconds(info.st_mtimespec)
        if cursor.inode == inode, cursor.device == device, cursor.size == size, cursor.mtimeMs == mtimeMs {
            Darwin.close(descriptor)
            return .unchanged
        }
        var next = cursor
        var startsOver = false
        if cursor.offset > 0 {
            let replaced = cursor.inode != inode || cursor.device != device
            if replaced || size < cursor.offset || hashOfTail(descriptor, before: cursor.offset) != cursor.tailHash {
                next.offset = 0
                next.tailHash = 0
                startsOver = true
            }
        }
        next.inode = inode
        next.device = device
        // The size and time from BEFORE reading: if the file grows while it is read, the next
        // scan sees a different size and looks again instead of missing the new lines.
        next.size = size
        next.mtimeMs = mtimeMs
        return .ready(JSONLTail(descriptor: descriptor, cursor: next, startsOver: startsOver, birthMs: milliseconds(info.st_birthtimespec)))
    }

    /// Calls `body` with the bytes of every complete, non-empty new line (without its newline).
    /// The bytes are only valid during the call.
    func forEachLine(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        var capacity = Self.chunkBytes
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var filled = 0                      // bytes in the buffer that are not consumed yet
        var consumed = cursor.offset        // file position of buffer[0]
        var skippingOversized = false

        while true {
            let got = pread(descriptor, buffer + filled, capacity - filled, consumed + Int64(filled))
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { break }           // end of file (or a read error: keep what was consumed so far)
            let scanFrom = filled
            filled += got

            var lineStart = 0
            var search = scanFrom
            while search < filled, let found = memchr(buffer + search, 0x0A, filled - search) {
                let newline = buffer.distance(to: found)
                if skippingOversized {
                    skippingOversized = false           // the oversized line ends here
                } else {
                    var length = newline - lineStart
                    if length > 0, (buffer + lineStart + length - 1).load(as: UInt8.self) == 0x0D { length -= 1 }
                    if length > 0 {
                        // Parsing a line leaves temporary objects behind; release them per line,
                        // or a long scan on a background queue piles them up until it ends.
                        try autoreleasepool { try body(UnsafeRawBufferPointer(start: buffer + lineStart, count: length)) }
                    }
                }
                lineStart = newline + 1
                search = lineStart
            }
            // Keep the unfinished last line at the front of the buffer for the next read.
            if lineStart > 0 {
                filled -= lineStart
                if filled > 0 { memmove(buffer, buffer + lineStart, filled) }
                consumed += Int64(lineStart)
            }
            if skippingOversized {
                consumed += Int64(filled)
                filled = 0
            } else if filled == capacity {
                if capacity < Self.maxLineBytes {
                    let larger = min(capacity * 2, Self.maxLineBytes)
                    let grown = UnsafeMutableRawPointer.allocate(byteCount: larger, alignment: 1)
                    grown.copyMemory(from: buffer, byteCount: filled)
                    buffer.deallocate()
                    buffer = grown
                    capacity = larger
                } else {
                    // One line larger than the cap: drop it and skip to its newline.
                    oversizedLines += 1
                    skippingOversized = true
                    consumed += Int64(filled)
                    filled = 0
                }
            }
        }
        cursor.offset = consumed
        cursor.tailHash = Self.hashOfTail(descriptor, before: consumed)
    }

    // MARK: Helpers

    private static func milliseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    /// FNV-1a hash of the (up to) 64 bytes that end at `offset`. 0 for an offset of 0.
    private static func hashOfTail(_ descriptor: Int32, before offset: Int64) -> UInt64 {
        guard offset > 0 else { return 0 }
        let count = Int(min(Int64(tailBytes), offset))
        var bytes = [UInt8](repeating: 0, count: count)
        let got = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset - Int64(count)) }
        guard got == count else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // 0 is reserved for "nothing read yet".
        return hash == 0 ? 1 : hash
    }
}

/// Small byte-level helpers shared by the readers. Lines are checked for a marker before they are
/// parsed, because most lines of a session file have nothing to do with usage.
enum LineBytes {
    /// True when `line` contains the ASCII text `marker`.
    static func contains(_ line: UnsafeRawBufferPointer, _ marker: StaticString) -> Bool {
        guard let base = line.baseAddress, marker.utf8CodeUnitCount > 0, line.count >= marker.utf8CodeUnitCount else { return false }
        return memmem(base, line.count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
    }

    /// Parses a line as a JSON object. Returns nil for anything else (malformed, an array, a number...).
    static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A whole, non-negative count from a JSON number. Anything else (missing, null, a bool,
    /// a negative or absurd number) counts as 0.
    static func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0, double < 1e15 else { return 0 }
        return Int(double)
    }

    /// A finite number from a JSON value, or nil.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// A non-empty string, or nil.
    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Milliseconds since 1970 for a timestamp like "2026-10-11T20:00:01.000Z" (the form every
    /// agent here writes), or any other ISO 8601 form as a slower fallback. Nil when it is not a time.
    static func timestampMs(_ value: Any?) -> Int64? {
        guard let text = value as? String else { return nil }
        if let fast = fastUTC(text) { return fast }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        if let date = ISO8601DateFormatter().date(from: text) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        return nil
    }

    /// "YYYY-MM-DDTHH:MM:SS[.fff…]Z" without going through a date formatter (it runs once per usage line).
    private static func fastUTC(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"), bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":") else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10), let hour = digits(11..<13),
              let minute = digits(14..<16), let second = digits(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var millis = 0
        if bytes.count > 20 {
            guard bytes[19] == UInt8(ascii: ".") else { return nil }
            var scale = 100
            for index in 20..<(bytes.count - 1) {
                let digit = Int(bytes[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                millis += digit * scale
                scale /= 10
            }
        }
        // Days since 1970-01-01 for a Gregorian date (the usual "days from civil" arithmetic).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Int64(((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + Int64(millis)
    }
}
