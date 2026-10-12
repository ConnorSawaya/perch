// Toast.swift — a short message that appears under the island for a few seconds.
//
// Used for things the user should know but that need no answer: "Could not jump to that
// terminal: …", "Diagnostics copied". It is a tiny window of its own that never takes the
// keyboard or the focus and lets clicks pass through.

import AppKit
import SwiftUI

final class ToastPresenter {
    /// How long a message stays up.
    static let visibleSeconds: TimeInterval = 4
    private static let size = CGSize(width: 460, height: 64)

    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// The message last shown (kept so tests and the debug channel can see it).
    private(set) var lastMessage: String?

    /// Shows `message` centred under `anchor` (a rectangle in screen coordinates — the island),
    /// or under the menu bar of the main screen when there is no island on screen.
    func show(_ message: String, systemImage: String, isProblem: Bool, settings: AppSettings, under anchor: CGRect?) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastMessage = message
        let panel = window ?? makeWindow()
        window = panel
        panel.contentView = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage, isProblem: isProblem)
            .environmentObject(settings))

        let size = Self.size
        var origin = CGPoint.zero
        if let anchor {
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        } else if let screen = NSScreen.main {
            origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 6)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let isProblem: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(isProblem ? theme.warning : theme.success)
            Text(message)
                .font(theme.font(.caption))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
        .background(Capsule().fill(theme.island))
        .overlay(Capsule().strokeBorder(theme.strokeStrong, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
