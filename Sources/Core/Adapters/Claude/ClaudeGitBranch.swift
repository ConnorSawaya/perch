// ClaudeGitBranch.swift — finds the git branch of a session's folder by reading one small file.
//
// Claude Code's hook payloads do not say which branch a session is on, but cards can show it.
// Git keeps the answer in `.git/HEAD` ("ref: refs/heads/main"), so reading that file is enough;
// no `git` process is started. Linked worktrees and submodules have a `.git` *file* that points
// at the real folder, which is followed once.

import Foundation

enum ClaudeGitBranch {
    /// How many parent folders to climb when looking for the repository root.
    private static let maxLevels = 24
    /// HEAD is one short line; anything bigger is not a HEAD file.
    private static let maxFileBytes = 4096

    /// The branch checked out in `folder` (or the repository that contains it). A detached HEAD
    /// gives the short commit id; a folder outside any repository gives nil.
    static func current(in folder: String) -> String? {
        guard folder.hasPrefix("/") else { return nil }
        var directory = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        for _ in 0..<maxLevels {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory = isDirectory.boolValue ? marker : linkedGitDirectory(marker, relativeTo: directory)
                return gitDirectory.flatMap { smallFile($0.appendingPathComponent("HEAD")) }.flatMap(branch(fromHEAD:))
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// Reads the contents of a HEAD file.
    static func branch(fromHEAD contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let name = String(line.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        // Detached HEAD: the file holds a commit id.
        let isCommit = line.count >= 7 && line.count <= 64 && line.allSatisfy(\.isHexDigit)
        return isCommit ? String(line.prefix(7)) : nil
    }

    /// A `.git` file contains "gitdir: <path>", absolute or relative to the folder it is in.
    private static func linkedGitDirectory(_ file: URL, relativeTo folder: URL) -> URL? {
        guard let line = smallFile(file)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                                   : folder.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private static func smallFile(_ url: URL) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
