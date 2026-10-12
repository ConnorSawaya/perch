// PerchScroll.swift — the vertical scrolling container used inside the island.
//
//   PerchScroll { VStack { ...cards... } }
//
// Why not a bare ScrollView? Two reasons:
//   1. Look: no scroll bars; instead the content fades out softly at the top and bottom edge.
//   2. Snapshots: SwiftUI cannot draw a real ScrollView into an image, so when the
//      `perchStaticRendering` environment value is true the content is laid out in place and
//      simply cut off at the bottom. The snapshot scripts set that value; the app never does.

import SwiftUI

private struct PerchStaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a view is being drawn into an image (snapshots). Scrolling containers then lay
    /// their content out in place, because real scroll views do not appear in images.
    var perchStaticRendering: Bool {
        get { self[PerchStaticRenderingKey.self] }
        set { self[PerchStaticRenderingKey.self] = newValue }
    }
}

struct PerchScroll<Content: View>: View {
    private let fadeEdges: Bool
    private let content: Content

    @Environment(\.perchStaticRendering) private var isStatic

    /// - Parameter fadeEdges: Fade the content out near the top and bottom edge. Give the content
    ///   about 8 points of padding at both ends so nothing important sits in the fade.
    init(fadeEdges: Bool = true, @ViewBuilder content: () -> Content) {
        self.fadeEdges = fadeEdges
        self.content = content()
    }

    var body: some View {
        Group {
            if isStatic {
                // Full natural height, but allowed to be cut short like a scroll view's viewport.
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollView(.vertical) { content }
                    .scrollIndicators(.never)
            }
        }
        .mask(edgeMask)
    }

    @ViewBuilder
    private var edgeMask: some View {
        if fadeEdges {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.2), .black], startPoint: .top, endPoint: .bottom).frame(height: 6)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
            }
        } else {
            Color.black
        }
    }
}
