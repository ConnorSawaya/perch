// ClaudeLocator.swift — finds out whether Claude Code is installed, and which version, by looking.
//
// Perch must not start `claude` just to ask for its version: that is slow, has hung other apps
// at launch, and an app started from Finder does not even have the shell's PATH. Every way of
// installing Claude Code leaves the version readable on disk instead:
//   - the native installer makes ~/.local/bin/claude a link to ~/.local/share/claude/versions/<version>;
//   - npm installs have a package.json next to the program the `claude` link points at;
//   - Homebrew keeps the program in a folder named after the version.
// So this file only follows links and reads names (and at most one small package.json).

import Foundation

struct ClaudeLocator {
    /// The user's home folder (tests point this at a temporary folder).
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Folders outside the home folder where a `claude` program may be.
    var systemFolders: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// The PATH to search as well (an app started from Finder has a very short one).
    var searchPath: String? = ProcessInfo.processInfo.environment["PATH"]

    struct Installation: Equatable {
        /// Where the `claude` program (or link) was found; nil when only the versions folder exists.
        var binaryPath: String?
        var version: ClaudeVersion?
    }

    /// The first Claude Code installation found, or nil when there is none.
    func find() -> Installation? {
        let fileManager = FileManager.default
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return Installation(binaryPath: path, version: version(ofBinaryAt: path) ?? newestNativeVersion())
        }
        // The versions folder without a link on the usual paths still means it is installed.
        return newestNativeVersion().map { Installation(binaryPath: nil, version: $0) }
    }

    /// Places to look for the `claude` program, most likely first, without duplicates.
    var candidatePaths: [String] {
        var folders = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", "bin"]
            .map { home.appendingPathComponent($0).path }
        folders += systemFolders
        folders += (searchPath ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }.map { $0 + "/claude" }
    }

    /// Reads the version from where the program really lives.
    func version(ofBinaryAt path: String) -> ClaudeVersion? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // Native install (".../claude/versions/2.1.296") and Homebrew (".../claude-code/2.1.296/..."):
        // the version is the folder or file name right after a folder we recognise.
        let parts = resolved.pathComponents
        for (index, part) in parts.enumerated().dropLast() where part == "versions" || part == "claude-code" {
            if let version = Self.exactVersion(parts[index + 1]) { return version }
        }
        // npm install: a package.json in one of the folders above the program names the version.
        var folder = resolved.deletingLastPathComponent()
        for _ in 0..<3 {
            if let version = packageVersion(in: folder) { return version }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// The highest version in the native installer's versions folder.
    func newestNativeVersion() -> ClaudeVersion? {
        let folder = home.appendingPathComponent(".local/share/claude/versions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(Self.exactVersion).max()
    }

    /// The version in a Claude Code package.json (and only in Claude Code's).
    private func packageVersion(in folder: URL) -> ClaudeVersion? {
        let file = folder.appendingPathComponent("package.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size < 1_000_000,
              let text = try? String(contentsOf: file, encoding: .utf8), let package = JSONValue.parse(text),
              package["name"].stringValue?.hasSuffix("claude-code") == true else { return nil }
        return package["version"].stringValue.flatMap(ClaudeVersion.init)
    }

    /// A name that is a version number and nothing else ("2.1.296", not "node-22.1.0").
    private static func exactVersion(_ name: String) -> ClaudeVersion? {
        guard let version = ClaudeVersion(name), version.description == name else { return nil }
        return version
    }
}
