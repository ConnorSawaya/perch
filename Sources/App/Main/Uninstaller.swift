// Uninstaller.swift — the steps of "Uninstall Perch" (Settings → Advanced), as plain functions.
//
// Uninstalling means, in this order:
//   1. take Perch's hooks out of every agent's settings file (each adapter removes only its own
//      lines and makes a backup first);
//   2. move everything in Perch's folder to the Trash — the helper, statistics, logs and the
//      backups of settings files. The Trash, not deletion, so a backup can still be fished out;
//   3. forget Perch's preferences and take it out of Login Items;
//   4. quit.
// AppController calls these in order and then quits. Each step reports what it could not do
// instead of stopping, so one unreadable file never leaves the rest half-removed.

import Foundation

enum Uninstaller {
    /// Removes Perch's hooks from every agent that has them. Returns one sentence per failure.
    static func removeHooks(adapters: [AgentAdapter]) -> [String] {
        var problems: [String] = []
        for adapter in adapters {
            let status = adapter.status()
            // Nothing of ours is in an agent that is absent or was never connected.
            guard status.hookStatus != .notDetected, status.hookStatus != .notInstalled else { continue }
            do {
                let summary = try adapter.uninstallHooks()
                Log.info("uninstall: \(adapter.kind.rawValue): \(summary)")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problems.append("\(adapter.kind.displayName): \(reason)")
            }
        }
        return problems
    }

    /// Moves everything inside `folder` to the Trash (the folder itself stays, empty). `trash` is
    /// a parameter so tests can watch instead of filling the real Trash. Returns one sentence per failure.
    static func emptyFolder(_ folder: URL, trash: (URL) throws -> Void = moveToTrash) -> [String] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var problems: [String] = []
        for item in items {
            do {
                try trash(item)
            } catch {
                // A socket cannot be put in the Trash; anything else that refuses is deleted outright
                // only if it is a leftover socket, and reported otherwise.
                if (try? item.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType == .socket {
                    try? fileManager.removeItem(at: item)
                } else {
                    problems.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return problems
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Forgets Perch's saved preferences. With PERCH_HOME they live in Perch's folder, which has
    /// just been emptied, so only the real store needs clearing.
    static func forgetPreferences(options: LaunchOptions) {
        guard !options.usesPrivateHome else { return }
        UserDefaults.standard.removePersistentDomain(forName: PerchPaths.bundleID)
    }
}
