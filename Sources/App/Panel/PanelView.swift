// PanelView.swift — the inside of the open panel, and the code that tells the window how tall
// the panel wants to be.
//
// Top to bottom:  PanelStrip (beside the notch) → PanelHeader (tabs + buttons) → the scrolling
// area with the chosen tab → PanelDemoBar (demo mode only).
//
// Height: every part measures its own natural height; the sum is clamped to the allowed range
// and written to `UIState.desiredPanelHeight` a moment later (never during a view update). The
// window shell and IslandRootView read that value through `IslandMetrics.panelSize`.
// The content inside the scroll area is measured at its full, unclipped height, so the result
// does not depend on the panel's current size (no feedback loop).

import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Sum of the natural heights of the parts below, as last measured.
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PanelStrip().measuresPanelHeight()
            PanelHeader().measuresPanelHeight()
            PerchScroll {
                tabContent
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.xs)
                    .padding(.bottom, Theme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .measuresPanelHeight()
            }
            if ui.isDemo {
                PanelDemoBar().measuresPanelHeight()
            }
        }
        .background(alignment: .top) {
            // The light only drifts while something is going on; otherwise it rests.
            AuroraHeader(isAnimating: sessions.busyCount + sessions.attentionCount > 0)
                .frame(height: ui.notchSize.height + 90)
        }
        .onPreferenceChange(PanelHeightKey.self) { naturalHeight = $0 }
        .onChange(of: wantedHeight, initial: true) { _, wanted in report(wanted) }
    }

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch ui.panelTab {
            case .sessions: SessionListView()
            case .usage: UsagePanelView()
            case .activity: ActivityPanelView()
            }
        }
        .id(ui.panelTab)
        .transition(.opacity)
        .animation(PerchMotion.fade(reduce: settings.prefersCalm(systemReduceMotion)), value: ui.panelTab)
    }

    /// The measured height, kept inside the limits the window allows. Zero until first measured.
    private var wantedHeight: CGFloat {
        guard naturalHeight > 0 else { return 0 }
        let limit = min(max(CGFloat(settings.panelMaxHeight), IslandMetrics.minPanelHeight), IslandMetrics.maxPanelHeight)
        return min(max(naturalHeight.rounded(.up), ui.notchSize.height + 60), limit)
    }

    private func report(_ wanted: CGFloat) {
        guard wanted > 0 else { return }
        let ui = self.ui
        // Deferred: changing shared state in the middle of a layout pass is not allowed.
        DispatchQueue.main.async {
            if abs(ui.desiredPanelHeight - wanted) > 0.5 { ui.desiredPanelHeight = wanted }
        }
    }
}

/// Adds up the natural heights of the panel's parts.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    /// Counts this view's height towards the height the panel asks for.
    func measuresPanelHeight() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
    }
}
