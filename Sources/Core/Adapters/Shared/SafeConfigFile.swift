// SafeConfigFile.swift — the careful way Perch reads and rewrites another program's config file.
//
// Every installer in the Codex, Antigravity and Gemini adapters goes through this file, so the
// safety rules from ARCHITECTURE.md §3 rule 2 are written exactly once:
//   - keep a timestamped copy of the original in Perch's backups folder before changing anything,
//   - write atomically (temporary file in the same folder, then rename over the original),
//   - keep the file's permissions, and write *through* a symlink instead of replacing the link,
//   - never touch a file whose content is identical to what would be written.

import Foundation

/// Why an install or uninstall stopped. `errorDescription` is a sentence fit for the Settings screen.
enum AdapterConfigError: Error, LocalizedError, Equatable {
    /// The agent is not on this Mac, so Perch will not create config folders for it.
    case agentNotDetected(String)
    /// The file exists but is not something Perch can edit without risking damage.
    case unsafeToEdit(path: String, reason: String)
    case ioFailure(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .agentNotDetected(let name):
            return "\(name) was not found on this Mac, so nothing was changed."
        case .unsafeToEdit(let path, let reason):
            return "Perch did not change \(path): \(reason)"
        case .ioFailure(let path, let reason):
            return "Could not write \(path): \(reason)"
        }
    }
}

enum SafeConfigFile {

    /// The file's text, or nil when it does not exist. Throws when it exists but cannot be read as UTF-8.
    static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw AdapterConfigError.ioFailure(path: url.path, reason: "the file could not be read.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AdapterConfigError.unsafeToEdit(path: url.path, reason: "it is not UTF-8 text.")
        }
        return text
    }

    /// Copies `url` into `backupsDir` as `<label>-<file name>.<timestamp>.bak`. Returns the copy, or nil
    /// when there was nothing to back up.
    @discardableResult
    static func backup(_ url: URL, label: String, backupsDir: URL, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            let stamp = timestampFormatter.string(from: now)
            var target = backupsDir.appendingPathComponent("\(label)-\(url.lastPathComponent).\(stamp).bak")
            var counter = 1
            // Two edits in the same second must not overwrite each other's backup.
            while fm.fileExists(atPath: target.path) {
                counter += 1
                target = backupsDir.appendingPathComponent("\(label)-\(url.lastPathComponent).\(stamp)-\(counter).bak")
            }
            try fm.copyItem(at: resolvingSymlink(url), to: target)
            return target
        } catch {
            throw AdapterConfigError.ioFailure(path: url.path, reason: "the backup failed (\(error.localizedDescription)).")
        }
    }

    /// Replaces the file's content atomically. Creates missing parent folders. A symlink is written
    /// through to its target, and an existing file keeps its permissions.
    static func writeAtomically(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let target = resolvingSymlink(url)
        let folder = target.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).perch-\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
            try Data(text.utf8).write(to: temp)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path) }
            guard rename(temp.path, target.path) == 0 else {
                throw AdapterConfigError.ioFailure(path: url.path, reason: String(cString: strerror(errno)))
            }
        } catch let error as AdapterConfigError {
            try? fm.removeItem(at: temp)
            throw error
        } catch {
            try? fm.removeItem(at: temp)
            throw AdapterConfigError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Backs up and rewrites `url`, unless `newText` is what the file already says. Returns true when
    /// the file changed.
    @discardableResult
    static func update(_ url: URL, to newText: String, label: String, backupsDir: URL) throws -> Bool {
        if try read(url) == newText { return false }
        try backup(url, label: label, backupsDir: backupsDir)
        try writeAtomically(newText, to: url)
        return true
    }

    /// Backs up and deletes a file Perch no longer needs.
    static func remove(_ url: URL, label: String, backupsDir: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try backup(url, label: label, backupsDir: backupsDir)
        do { try FileManager.default.removeItem(at: url) } catch {
            throw AdapterConfigError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
    }

    // MARK: "Perch created this file" marks

    // Uninstall deletes a config file only when Perch made it in the first place. That fact is kept
    // as a small marker file next to the backups, so nothing extra is written into the agent's folder.

    private static func createdMark(for url: URL, label: String, backupsDir: URL) -> URL {
        backupsDir.appendingPathComponent("\(label)-\(url.lastPathComponent).created-by-perch")
    }

    static func markCreatedByPerch(_ url: URL, label: String, backupsDir: URL) {
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try? Data(url.path.utf8).write(to: createdMark(for: url, label: label, backupsDir: backupsDir))
    }

    static func wasCreatedByPerch(_ url: URL, label: String, backupsDir: URL) -> Bool {
        let mark = createdMark(for: url, label: label, backupsDir: backupsDir)
        guard let recorded = try? String(contentsOf: mark, encoding: .utf8) else { return false }
        return recorded == url.path
    }

    static func clearCreatedMark(_ url: URL, label: String, backupsDir: URL) {
        try? FileManager.default.removeItem(at: createdMark(for: url, label: label, backupsDir: backupsDir))
    }

    /// Follows a symlink so the rename lands on the real file. Anything else is returned unchanged.
    private static func resolvingSymlink(_ url: URL) -> URL {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
        let resolved = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
        return resolved.standardizedFileURL
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// Where the adapters find things. The no-argument adapters use `live`; tests build their own.
struct AdapterEnvironment {
    /// The user's home folder.
    var home: URL
    /// Absolute path of the installed `perch-hook` helper.
    var helperPath: String
    /// Where backups of edited config files go.
    var backupsDir: URL
    /// Environment variables (only a few agent-specific ones are read, such as CODEX_HOME).
    var variables: [String: String]
    /// Finds an installed app by bundle identifier. Injected so tests never ask LaunchServices.
    var appLookup: (String) -> URL?

    static var live: AdapterEnvironment {
        AdapterEnvironment(home: FileManager.default.homeDirectoryForCurrentUser,
                           helperPath: PerchPaths.helperURL.path,
                           backupsDir: PerchPaths.backupsDir,
                           variables: ProcessInfo.processInfo.environment,
                           appLookup: LaunchServicesLookup.url(forBundleID:))
    }
}

/// Shell quoting for hook command strings that an agent passes to `sh -c`.
enum ShellQuote {
    /// Wraps `text` in single quotes so spaces and symbols reach the program unchanged.
    static func single(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
