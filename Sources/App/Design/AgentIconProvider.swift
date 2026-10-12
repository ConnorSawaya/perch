// AgentIconProvider.swift — finds the real app icon for an agent, the same way the Dock does.
//
// Perch ships no vendor artwork. Instead, when an agent's desktop app is installed on this Mac,
// we ask macOS for that app's own icon and show it in the AgentBadge. When no matching app is
// installed (or the agent has no desktop app at all) the answer is nil and the badge draws its
// monogram instead.
//
// Answers are remembered. An app that is installed or removed later is noticed the next time a
// badge is drawn after `recheckInterval` has passed, or at once after `refresh()`.
//
// Snapshots and tests must not depend on what happens to be installed, so they set
// `AgentIconProvider.shared.source` to `.monogramOnly` or to `.fixed([...])` with their own images.

import AppKit

@MainActor
final class AgentIconProvider {
    static let shared = AgentIconProvider()

    /// Where badge icons come from.
    enum Source {
        /// Look for the agent's installed app (what the running app does).
        case installedApps
        /// Never show an app icon; every badge draws its monogram.
        case monogramOnly
        /// Use exactly these images; agents not listed draw their monogram.
        case fixed([AgentKind: NSImage])
    }

    var source: Source = .installedApps {
        didSet { refresh() }
    }

    /// How long an answer (found or not found) is trusted before looking again.
    var recheckInterval: TimeInterval = 300

    private struct Answer {
        let appURL: URL?
        let image: CGImage?
        let checkedAt: Date
    }

    private var answers: [AgentKind: Answer] = [:]

    /// The agent's app icon, trimmed to its visible artwork, or nil when the monogram should show.
    func icon(for agent: AgentKind) -> CGImage? {
        answer(for: agent).image
    }

    /// The installed app the icon came from, if one was found.
    func appURL(for agent: AgentKind) -> URL? {
        answer(for: agent).appURL
    }

    /// Forget every answer, so the next badge drawn looks again.
    func refresh() {
        answers.removeAll()
    }

    // MARK: - Looking up

    private func answer(for agent: AgentKind) -> Answer {
        if let known = answers[agent], Date().timeIntervalSince(known.checkedAt) < recheckInterval {
            return known
        }
        let fresh = lookUp(agent)
        answers[agent] = fresh
        return fresh
    }

    private func lookUp(_ agent: AgentKind) -> Answer {
        switch source {
        case .monogramOnly:
            return Answer(appURL: nil, image: nil, checkedAt: Date())
        case .fixed(let images):
            return Answer(appURL: nil, image: images[agent].flatMap(Self.trimmedArtwork), checkedAt: Date())
        case .installedApps:
            guard let url = Self.installedApp(for: agent) else {
                return Answer(appURL: nil, image: nil, checkedAt: Date())
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return Answer(appURL: url, image: Self.trimmedArtwork(icon), checkedAt: Date())
        }
    }

    /// Bundle identifiers to try, in order, then app names to look for in the Applications folders.
    private static func candidates(for agent: AgentKind) -> (bundleIDs: [String], appNames: [String]) {
        switch agent {
        case .claude: return (["com.anthropic.claudefordesktop"], ["Claude"])
        case .codex: return (["com.openai.codex", "com.openai.chat"], ["Codex", "ChatGPT"])
        case .antigravity: return (["com.google.antigravity", "com.google.antigravity-ide"], ["Antigravity"])
        case .gemini: return ([], [])   // command-line only: there is no desktop app to borrow an icon from
        }
    }

    private static func installedApp(for agent: AgentKind) -> URL? {
        let (bundleIDs, appNames) = candidates(for: agent)
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        for name in appNames {
            for folder in folders {
                let url = folder.appendingPathComponent("\(name).app", isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: - Preparing the picture

    /// The largest version of `icon`, cropped to the square around its visible artwork. macOS app
    /// icons carry a transparent margin; without the crop the icon would look small in the badge.
    private static func trimmedArtwork(_ icon: NSImage) -> CGImage? {
        let largest = icon.representations.max { $0.pixelsWide < $1.pixelsWide }
        let side = max(largest?.pixelsWide ?? 0, 256)
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let full = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        guard let visible = visibleSquare(of: full) else { return full }
        return full.cropping(to: visible) ?? full
    }

    /// The centred square that encloses every clearly visible pixel (soft shadows are ignored).
    private static func visibleSquare(of image: CGImage) -> CGRect? {
        let probe = 128
        var alpha = [UInt8](repeating: 0, count: probe * probe)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: probe, height: probe, bitsPerComponent: 8,
                                          bytesPerRow: probe, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
            return true
        }
        guard drawn else { return nil }

        // Distance from the centre to the farthest solid pixel, in probe pixels.
        let centre = CGFloat(probe) / 2
        var reach: CGFloat = 0
        for y in 0..<probe {
            for x in 0..<probe where alpha[y * probe + x] > 128 {
                let dx = max(centre - CGFloat(x), CGFloat(x + 1) - centre)
                let dy = max(centre - CGFloat(y), CGFloat(y + 1) - centre)
                reach = max(reach, dx, dy)
            }
        }
        guard reach > 0 else { return nil }
        let fraction = min(1, reach / centre)
        let width = CGFloat(image.width) * fraction
        let height = CGFloat(image.height) * fraction
        return CGRect(x: (CGFloat(image.width) - width) / 2, y: (CGFloat(image.height) - height) / 2,
                      width: width, height: height).integral
    }
}
