// FileDefaults.swift — preferences kept in a file of our choosing (or only in memory).
//
// AppSettings saves every toggle through a UserDefaults object. Normally that is the system's
// standard store for the app (`~/Library/Preferences/local.perch.app.plist`). Two situations
// must not touch that real store:
//
//   - a run with PERCH_HOME set (tests, experiments): preferences then live in
//     `$PERCH_HOME/preferences.plist`, next to everything else that run creates, so removing the
//     folder removes every trace — and a test can choose its settings by writing that file first;
//   - `--snapshot`, which changes themes and text sizes only to draw them: memory only.
//
// The class overrides exactly the five calls AppSettings uses, so nothing ever reaches the
// system's preference store through it.

import Foundation

final class FileDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    /// Where the values are saved after every change; nil keeps them in memory only.
    private var fileURL: URL?

    /// Preferences that are forgotten when the app quits.
    static func inMemory() -> FileDefaults { FileDefaults() }

    /// Preferences read from, and saved to, a property-list file. A missing or unreadable file
    /// simply means "all defaults".
    static func file(_ url: URL) -> FileDefaults {
        let defaults = FileDefaults()
        defaults.fileURL = url
        if let data = try? Data(contentsOf: url),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            defaults.values = saved
        }
        return defaults
    }

    /// The right store for this launch: the real one, unless PERCH_HOME redirects Perch's files.
    static func forLaunch(_ options: LaunchOptions) -> UserDefaults {
        options.usesPrivateHome ? file(PerchPaths.supportDir.appendingPathComponent("preferences.plist")) : .standard
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        save()
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
        save()
    }

    override func dictionaryRepresentation() -> [String: Any] { values }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("could not save preferences to \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
