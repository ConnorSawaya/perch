// JSONLinesTailer.swift — reads the lines that were appended to a growing ".jsonl" file.
//
// Agents such as Codex write one JSON object per line to a session file while they work. A
// tailer remembers how far it has read, and each call to `readNewLines()` returns only the
// complete lines added since the last call. A half-written last line is left for next time.
//
// It never loads the whole file: at most `maxBytesPerRead` bytes are read per call, so a huge
// session file cannot stall the app.

import Foundation

final class JSONLinesTailer {
    let url: URL
    /// Byte position of the first unread byte.
    private(set) var offset: UInt64
    private let maxBytesPerRead: Int
    /// A single line longer than this is skipped instead of being buffered forever.
    private let maxLineBytes: Int

    /// - Parameter startAtEnd: true to ignore what is already in the file and report only new lines.
    init(url: URL, startAtEnd: Bool, maxBytesPerRead: Int = 512 * 1024, maxLineBytes: Int = 4 * 1024 * 1024) {
        self.url = url
        self.maxBytesPerRead = max(1024, maxBytesPerRead)
        self.maxLineBytes = max(self.maxBytesPerRead, maxLineBytes)
        self.offset = startAtEnd ? JSONLinesTailer.fileSize(url) : 0
    }

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Complete lines appended since the last call (without their newline; empty lines dropped).
    /// Returns an empty array when nothing new is there or the file cannot be read.
    func readNewLines() -> [String] {
        let size = JSONLinesTailer.fileSize(url)
        // The file shrank: it was replaced or truncated, so start again from the top.
        if size < offset { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var window = maxBytesPerRead
        while true {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: window), !data.isEmpty else { return [] }
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                // No complete line in this window. Look further only while the line could still be sane.
                if data.count < window { return [] }                 // the writer has not finished the line yet
                if window >= maxLineBytes {                          // absurdly long line: skip past it
                    offset += UInt64(data.count)
                    return []
                }
                window = min(window * 4, maxLineBytes)
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            offset += UInt64(complete.count)
            return complete.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { slice in
                let line = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }
        }
    }

    /// The last `maxBytes` of a file as complete lines, oldest first. Used to peek at recent history
    /// (for example the latest usage record) without reading a whole session file.
    static func tailLines(of url: URL, maxBytes: Int = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = fileSize(url)
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // When the read began mid-file the first piece is the tail end of a line: drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The first line of a file (session files start with a header record), reading at most `maxBytes`.
    static func firstLine(of url: URL, maxBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), let newline = data.firstIndex(of: 0x0A) else { return nil }
        return String(decoding: data[data.startIndex..<newline], as: UTF8.self)
    }
}
