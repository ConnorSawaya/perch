// ClaudeSettingsFile.swift — reads and writes Claude Code's settings.json on disk, carefully.
//
// The rules (ARCHITECTURE.md §3 rule 2): never clobber the file, keep a timestamped backup of
// what was there before every change, and replace the file in one step so that neither Claude
// Code nor a crash can ever see half of it. A settings file that is a symbolic link (dotfiles
// setups) stays a link: the file it points at is the one replaced.

import Foundation

struct ClaudeSettingsFile {
    /// `<config dir>/settings.json`.
    let url: URL
    /// Where copies of the previous contents go (normally PerchPaths.backupsDir).
    let backupsDir: URL

    /// How many of our backups of this file to keep.
    static let backupsToKeep = 10
    static let backupPrefix = "claude-settings-"
    /// A settings file is a few kilobytes. Something far bigger is not one, and is left alone.
    static let maxBytes = 5 * 1024 * 1024

    struct Contents {
        var document: ClaudeSettingsDocument
        /// The bytes on disk, nil when there is no file yet.
        var original: Data?
    }

    /// Reads and parses the file. A missing file gives an empty document.
    func read() throws -> Contents {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Contents(document: try ClaudeSettingsDocument(text: "", path: path), original: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ClaudeInstallError.unreadable(path: path, reason: error.localizedDescription)
        }
        guard data.count <= Self.maxBytes else {
            throw ClaudeInstallError.unexpectedShape(path: path, problem: "it is far larger than a settings file should be")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClaudeInstallError.notJSON(path: path, line: 1, reason: "the file is not UTF-8 text")
        }
        return Contents(document: try ClaudeSettingsDocument(text: text, path: path), original: data)
    }

    /// Saves new contents: backs up `original` first (when there was a file), then swaps the new
    /// file into place in one step. Returns where the backup went.
    @discardableResult
    func write(_ text: String, replacing original: Data?) throws -> URL? {
        let fileManager = FileManager.default
        // Follow a symbolic link so the link itself survives and its target gets the new contents.
        let target = original == nil ? url : url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = try original.map(saveBackup)

            let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).perch-\(UUID().uuidString).tmp")
            try Data(text.utf8).write(to: temporary)
            // The new file keeps the old one's permissions (some people keep secrets in "env").
            if let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, target.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fileManager.removeItem(at: temporary)
                throw ClaudeInstallError.writeFailed(path: url.path, reason: reason)
            }
            return backup
        } catch let error as ClaudeInstallError {
            throw error
        } catch {
            throw ClaudeInstallError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Deletes the file. Used only for a file Perch created itself that is empty again.
    func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Backups

    private func saveBackup(_ data: Data) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var backup = backupsDir.appendingPathComponent("\(Self.backupPrefix)\(stamp).json")
        var counter = 2
        while fileManager.fileExists(atPath: backup.path) {
            backup = backupsDir.appendingPathComponent("\(Self.backupPrefix)\(stamp)-\(counter).json")
            counter += 1
        }
        try data.write(to: backup)
        // Readable by the user only: the settings file may hold tokens in its "env" section.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        pruneBackups()
        return backup
    }

    /// Keeps the newest few backups of this file and removes older ones (only files we named).
    private func pruneBackups() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: backupsDir.path) else { return }
        // The timestamp in the name sorts the same way as time does.
        let ours = names.filter { $0.hasPrefix(Self.backupPrefix) && $0.hasSuffix(".json") }.sorted()
        for name in ours.dropLast(Self.backupsToKeep) {
            try? fileManager.removeItem(at: backupsDir.appendingPathComponent(name))
        }
    }
}
