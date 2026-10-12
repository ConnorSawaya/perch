// Support.swift — small shared helpers: logging and off-screen snapshots.

import Foundation
import SwiftUI
import AppKit

/// Minimal logging. Everything goes to ~/Library/Application Support/Perch/logs/perch.log.
/// `debug` lines are only written when AppSettings.debugLogging is on (set `Log.debugEnabled`).
enum Log {
    static var debugEnabled = false
    private static let queue = DispatchQueue(label: "local.perch.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let maxBytes = 2_000_000

    static func info(_ message: @autoclosure () -> String, _ area: String = "app") { write("INFO", area, message()) }
    static func error(_ message: @autoclosure () -> String, _ area: String = "app") { write("ERROR", area, message()) }
    static func debug(_ message: @autoclosure () -> String, _ area: String = "app") {
        if debugEnabled { write("DEBUG", area, message()) }
    }

    static var fileURL: URL { PerchPaths.logsDir.appendingPathComponent("perch.log") }

    private static func write(_ level: String, _ area: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(area)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: PerchPaths.logsDir, withIntermediateDirectories: true)
            let url = fileURL
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Renders SwiftUI views to PNG files without showing a window. Used by `scripts/snapshot.sh`
/// so the look of each screen can be checked (and reviewed) without launching the app.
/// Animations are captured at their starting frame; materials and AppKit-backed views may not render.
@MainActor
enum Snapshot {
    /// Renders `view` at `size` points (2x pixels) on `background` and writes `<name>.png` into `directory`.
    @discardableResult
    static func write<V: View>(_ view: V, name: String, size: CGSize, to directory: URL,
                               background: Color = Color(red: 0.16, green: 0.17, blue: 0.2)) -> URL? {
        _ = NSApplication.shared
        let content = ZStack(alignment: .top) {
            background
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot failed: \(name)")
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        do { try png.write(to: url) } catch { print("snapshot write failed: \(name): \(error)"); return nil }
        print("snapshot: \(url.path)")
        return url
    }
}
