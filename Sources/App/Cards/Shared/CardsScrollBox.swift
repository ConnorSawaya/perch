// CardsScrollBox.swift — a box that is as tall as its content up to a limit, and scrolls after that.
//
//   CardsScrollBox(maxHeight: 220) { ...a long diff, plan or JSON blob... }
//
// The request cards and tabs sit inside the panel's own scrolling area, so they must not scroll
// as a whole. Only the long things inside them (a diff, a plan, raw JSON) get one of these.
//
// How it sizes itself: an invisible copy of the content is laid out first and capped at
// `maxHeight`; the real, scrolling copy is then placed on top at exactly that size. That keeps
// short content snug without measuring anything after the fact (no flicker, no state).
//
// Snapshots: a real scroll view draws nothing in an image, so with `perchStaticRendering` the
// content is simply laid out in place and cut off at the limit.

import SwiftUI

struct CardsScrollBox<Content: View>: View {
    private let maxHeight: CGFloat
    private let content: Content

    @Environment(\.perchStaticRendering) private var isStatic

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        // The outer fixedSize makes the cap apply to the content's own height, whatever height
        // the surrounding layout happens to offer.
        let sizer = content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maxHeight, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        if isStatic {
            sizer.clipped()
        } else {
            sizer
                .hidden()
                .overlay {
                    ScrollView(.vertical) { content }
                        .scrollIndicators(.automatic)
                }
        }
    }
}

/// One row of content that may be wider than the space it gets: it scrolls sideways.
/// The height must be given because a sideways scroll view has no natural height of its own
/// in a snapshot. The right edge fades out as a hint that there may be more.
struct CardsSidewaysScroll<Content: View>: View {
    private let height: CGFloat
    private let content: Content

    @Environment(\.perchStaticRendering) private var isStatic

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        Group {
            if isStatic {
                Color.clear
                    .overlay(alignment: .topLeading) { content.fixedSize() }
                    .clipped()
            } else {
                ScrollView(.horizontal) { content }
                    .scrollIndicators(.never)
            }
        }
        .frame(height: height, alignment: .top)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}
