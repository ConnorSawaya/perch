// HelperInstaller.swift — keeps a copy of the `perch-hook` helper at a fixed place on disk.
//
// The helper ships inside Perch.app, but agents' hook settings need a path that stays the same
// when the app is moved or updated. So on every launch the app copies the helper to
// PerchPaths.helperURL (~/Library/Application Support/Perch/bin/perch-hook) unless an identical
// copy is already there.
//
// The copy is swapped into place in a single step (write a temporary file next to it, then
// rename). An agent that runs a hook at that very moment gets either the old helper or the new
// one, never a half-written file.

import Foundation

enum HelperInstallError: Error, Equatable, LocalizedError {
    /// The helper that should be inside the app bundle is not there (or cannot be read).
    case bundledHelperMissing(path: String)
    /// A file-system step failed. `code` is the errno value.
    case system(step: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing(let path):
            return "The hook helper is missing from the app (expected at \(path)). Rebuild or reinstall Perch."
        case .system(let step, let code):
            return "Could not \(step): \(String(cString: strerror(code))) (error \(code))."
        }
    }
}

enum HelperInstaller {
    /// Where build.sh puts the helper inside the running app: Perch.app/Contents/Helpers/perch-hook.
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(PerchPaths.helperName)")
    }

    /// True when an executable helper is in place at PerchPaths.helperURL.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: PerchPaths.helperURL.path)
    }

    /// Makes PerchPaths.helperURL an executable copy of `bundledHelper`, creating folders as
    /// needed. Leaves the installed file untouched when it already has the same contents.
    static func install(from bundledHelper: URL) throws {
        guard let wanted = try? Data(contentsOf: bundledHelper), !wanted.isEmpty else {
            throw HelperInstallError.bundledHelperMissing(path: bundledHelper.path)
        }
        let destination = PerchPaths.helperURL
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let installed = try? Data(contentsOf: destination), installed == wanted {
            try makeExecutable(destination)
            return
        }

        let temporary = folder.appendingPathComponent(".\(PerchPaths.helperName).\(UUID().uuidString).tmp")
        do {
            try wanted.write(to: temporary)
            try makeExecutable(temporary)
            guard rename(temporary.path, destination.path) == 0 else {
                throw HelperInstallError.system(step: "move the hook helper into place", code: errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        Log.info("installed the hook helper at \(destination.path)", "runtime")
    }

    /// rwxr-xr-x: the agents run the helper as the current user.
    private static func makeExecutable(_ url: URL) throws {
        guard chmod(url.path, 0o755) == 0 else {
            throw HelperInstallError.system(step: "make the hook helper executable", code: errno)
        }
    }
}
