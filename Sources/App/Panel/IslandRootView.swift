// IslandRootView.swift — the root of everything drawn in the notch window.
//
// The window is a fixed, transparent rectangle (IslandMetrics.windowSize) pinned to the top of
// the screen. This view draws the black island at its top-centre, flush with the top edge:
//   • collapsed → the pill (PillView), exactly IslandMetrics.pillSize
//   • expanded  → the panel (PanelView), exactly IslandMetrics.panelSize
// One IslandShape is used for both; its frame and corner radii spring between the two sizes,
// and the content is clipped to it so the panel seems to grow out of the notch.
//
// This view only DRAWS `ui.isExpanded`. Deciding when to open or close (hover, clicks outside,
// keyboard) belongs to the window shell.

import SwiftUI

struct IslandRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init() {}

    var body: some View {
        let theme = Theme.current(settings)
        let expanded = ui.isExpanded
        let pill = IslandMetrics.pillSize(ui: ui, settings: settings)
        let panel = IslandMetrics.panelSize(ui: ui, settings: settings)
        let size = expanded ? panel : pill
        let calm = settings.prefersCalm(systemReduceMotion)
        let ear = min(expanded ? 10 : Theme.Radius.notchEar, ui.notchSize.height / 2)
        let corner = expanded ? Theme.Radius.panel : min(Theme.Radius.pill, pill.height / 2)
        let needsUser = sessions.attentionCount > 0

        ZStack(alignment: .top) {
            // 1. The black body, with a shadow only when open (the pill must look like part of the notch).
            IslandShape(topRadius: ear, bottomRadius: corner)
                .fill(theme.island)
                .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 22, y: 12)
                .frame(width: size.width, height: size.height)

            // 2. The content, laid out at its final size and revealed by the growing shape.
            ZStack(alignment: .top) {
                if expanded {
                    PanelView()
                        .frame(width: panel.width, height: panel.height, alignment: .top)
                        .transition(.asymmetric(insertion: calm ? .opacity : .perchReveal, removal: .perchQuickFade))
                } else {
                    PillView()
                        .frame(width: pill.width, height: pill.height)
                        .transition(.asymmetric(insertion: .perchLateFade, removal: .perchQuickFade))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(IslandShape(topRadius: ear, bottomRadius: corner))

            // 3. A hairline around the open panel so it reads against dark windows behind it.
            IslandShape(topRadius: ear, bottomRadius: corner, closed: false)
                .stroke(LinearGradient(colors: [theme.stroke.opacity(0), theme.strokeStrong], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                .frame(width: size.width, height: size.height)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(false)

            // 4. The "something needs you" glow along the edge.
            //    Softer on the open panel, where the request cards already draw the eye.
            GlowBorder(IslandShape(topRadius: ear, bottomRadius: corner, closed: false),
                       lineWidth: expanded ? 1 : 1.5, blur: expanded ? 9 : 6, isActive: needsUser)
                .frame(width: size.width, height: size.height)
                .opacity(expanded ? 0.7 : 1)

            // 5. Confetti falling from the pill when a session finishes (cards have their own).
            //    It starts in the left wing and may fall a little way outside the pill.
            if !expanded {
                let overhang: CGFloat = 110
                let burstSize = CGSize(width: pill.width + overhang * 2, height: pill.height + 150)
                SessionDoneBurst(sessionID: nil,
                                 origin: UnitPoint(x: (overhang + IslandMetrics.wing(settings) / 2) / burstSize.width,
                                                   y: pill.height / 2 / burstSize.height),
                                 style: .shower)
                    .frame(width: burstSize.width, height: burstSize.height)
            }
        }
        .frame(width: IslandMetrics.windowSize.width, height: IslandMetrics.windowSize.height, alignment: .top)
        .animation(PerchMotion.morph(reduce: calm), value: expanded)
        .animation(PerchMotion.morph(reduce: calm), value: size)
        // The island is always dark, whatever the system appearance (affects menus and tooltips).
        .environment(\.colorScheme, .dark)
    }
}

private extension AnyTransition {
    /// The panel's entrance: it fades in while un-blurring and settling down from the notch.
    static var perchReveal: AnyTransition {
        .modifier(active: RevealModifier(progress: 0), identity: RevealModifier(progress: 1))
    }

    /// Whatever is leaving gets out of the way fast, so pill and panel text never overlap for long.
    static var perchQuickFade: AnyTransition {
        .opacity.animation(.easeOut(duration: 0.09))
    }

    /// The pill's content returns only once the island has nearly finished shrinking.
    static var perchLateFade: AnyTransition {
        .opacity.animation(.easeOut(duration: 0.16).delay(0.16))
    }
}

private struct RevealModifier: ViewModifier {
    /// 0 = hidden (blurred, slightly small, transparent), 1 = fully shown.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.94 + 0.06 * progress, anchor: .top)
    }
}
