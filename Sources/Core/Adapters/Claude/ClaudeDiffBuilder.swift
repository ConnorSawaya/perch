// ClaudeDiffBuilder.swift — builds the small "what will change" preview on an approval card.
//
// When Claude Code asks permission to edit or write a file, the request carries the old and new
// text (Edit, MultiEdit), the whole new file (Write) or a notebook cell (NotebookEdit). This file
// turns those into a DiffPreview: lines marked added / removed / unchanged, with long unchanged
// stretches folded away. The line comparison is a plain longest-common-subsequence diff written
// for this project. The view decides how many lines to show (settings.diffMaxLines); we only stop
// a huge edit from producing a huge preview.

import Foundation

enum ClaudeDiffBuilder {
    /// The most lines a preview may hold. More than this sets `truncated`.
    static let maxLines = 400
    /// Unchanged lines kept on each side of a change.
    static let contextLines = 3
    /// An existing file larger than this is not read for comparison (a Write then shows as all new).
    static let maxExistingFileBytes = 256 * 1024
    /// The comparison table has (old lines × new lines) cells; above this we fall back to
    /// "everything removed, everything added" instead of spending memory and time on the main thread.
    static let maxComparisonCells = 1_000_000

    /// Reads the current contents of a file about to be overwritten. Nil when it does not exist,
    /// is too large, or is not text.
    static func readExistingFile(_ path: String) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int, size <= maxExistingFileBytes,
              (attributes?[.type] as? FileAttributeType) == .typeRegular,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - From a tool call to a preview

    /// The preview for a file-changing tool, or nil for every other tool.
    /// `existingFile` is a parameter so tests do not depend on what is on disk.
    static func preview(tool: String, input: JSONValue, cwd: String?,
                        existingFile: (String) -> String? = readExistingFile) -> DiffPreview? {
        var lines: [DiffLine]
        let path: String?
        switch tool {
        case "Edit":
            guard input["old_string"].stringValue != nil || input["new_string"].stringValue != nil else { return nil }
            path = input["file_path"].stringValue
            lines = input["replace_all"].boolValue == true ? [DiffLine(kind: .header, text: "Every occurrence is replaced")] : []
            lines += editLines(old: input["old_string"].stringValue ?? "", new: input["new_string"].stringValue ?? "")
        case "MultiEdit":
            guard let edits = input["edits"].arrayValue, !edits.isEmpty else { return nil }
            path = input["file_path"].stringValue
            lines = []
            for (index, edit) in edits.enumerated() {
                if edits.count > 1 { lines.append(DiffLine(kind: .header, text: "Change \(index + 1) of \(edits.count)")) }
                lines += editLines(old: edit["old_string"].stringValue ?? "", new: edit["new_string"].stringValue ?? "")
            }
        case "Write":
            guard let content = input["content"].stringValue else { return nil }
            path = input["file_path"].stringValue
            if let path, let current = existingFile(path) {
                lines = editLines(old: current, new: content)
            } else {
                lines = splitLines(content).map { DiffLine(kind: .added, text: $0) }
            }
        case "NotebookEdit":
            path = input["notebook_path"].stringValue
            let cell = input["cell_id"].stringValue.map { " \($0)" } ?? ""
            switch input["edit_mode"].stringValue ?? "replace" {
            case "delete":
                lines = [DiffLine(kind: .header, text: "Delete cell\(cell)")]
            case "insert":
                lines = [DiffLine(kind: .header, text: "Insert a new cell")]
                lines += splitLines(input["new_source"].stringValue ?? "").map { DiffLine(kind: .added, text: $0) }
            default:
                lines = [DiffLine(kind: .header, text: "Replace cell\(cell)")]
                lines += splitLines(input["new_source"].stringValue ?? "").map { DiffLine(kind: .added, text: $0) }
            }
        default:
            return nil
        }
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        let truncated = lines.count > maxLines
        return DiffPreview(filePath: path.map { ClaudeToolDescriber.displayPath($0, cwd: cwd) },
                           lines: truncated ? Array(lines.prefix(maxLines)) : lines,
                           added: added, removed: removed, truncated: truncated)
    }

    /// The folded diff between two pieces of text.
    static func editLines(old: String, new: String) -> [DiffLine] {
        fold(lineDiff(old: splitLines(old), new: splitLines(new)), context: contextLines)
    }

    // MARK: - Line diff

    /// Splits text into lines. A final line break does not produce an extra empty line.
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Compares two lists of lines and returns every line marked as unchanged, removed or added,
    /// in reading order (removals before the additions that replace them).
    static func lineDiff(old: [String], new: [String]) -> [DiffLine] {
        // Lines shared at the start and the end need no comparison; most edits touch a small middle.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }

        var result = old[..<start].map { DiffLine(kind: .context, text: $0) }
        result += middleDiff(Array(old[start..<oldEnd]), Array(new[start..<newEnd]))
        result += old[oldEnd...].map { DiffLine(kind: .context, text: $0) }
        return result
    }

    /// Longest-common-subsequence diff of the part that actually differs.
    private static func middleDiff(_ old: [String], _ new: [String]) -> [DiffLine] {
        let removedAll = old.map { DiffLine(kind: .removed, text: $0) }
        let addedAll = new.map { DiffLine(kind: .added, text: $0) }
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= maxComparisonCells else { return removedAll + addedAll }

        // common[i][j] = how many lines old[i...] and new[j...] share, in order. Filled from the end.
        let width = new.count + 1
        var common = [Int32](repeating: 0, count: (old.count + 1) * width)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                common[i * width + j] = old[i] == new[j]
                    ? common[(i + 1) * width + j + 1] + 1
                    : max(common[(i + 1) * width + j], common[i * width + j + 1])
            }
        }
        var result: [DiffLine] = []
        result.reserveCapacity(old.count + new.count)
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(DiffLine(kind: .context, text: old[i])); i += 1; j += 1
            } else if common[(i + 1) * width + j] >= common[i * width + j + 1] {
                result.append(DiffLine(kind: .removed, text: old[i])); i += 1
            } else {
                result.append(DiffLine(kind: .added, text: new[j])); j += 1
            }
        }
        result += removedAll[i...]
        result += addedAll[j...]
        return result
    }

    // MARK: - Folding unchanged lines

    /// Keeps `context` unchanged lines around each change and replaces longer unchanged stretches
    /// with one header line saying how many lines were skipped. Text with no changes at all is
    /// returned as it is.
    static func fold(_ lines: [DiffLine], context: Int) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return lines }
        var keep = [Bool](repeating: false, count: lines.count)
        for index in changed {
            for near in max(0, index - context)...min(lines.count - 1, index + context) { keep[near] = true }
        }
        var result: [DiffLine] = []
        var index = 0
        while index < lines.count {
            if keep[index] { result.append(lines[index]); index += 1; continue }
            var end = index
            while end < lines.count, !keep[end] { end += 1 }
            let skipped = end - index
            if skipped == 1 {
                result.append(lines[index])   // a note saying "1 line skipped" would be no shorter than the line
            } else {
                result.append(DiffLine(kind: .header, text: "⋯ \(skipped) unchanged lines"))
            }
            index = end
        }
        return result
    }
}
