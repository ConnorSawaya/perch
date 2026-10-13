// SettingsPage.swift — the frame around every Settings page: the page's icon, name and one-line
// description at the top, and the page's sections underneath.
//
// Every page is designed to fit the window as it opens (860 x 620) with nothing to scroll. The
// sections still sit in a scrolling container, so a smaller window or larger text loses nothing.

import SwiftUI

struct SettingsPage: View {
    let page: SettingsPageID

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 0) {
            header(theme)
                .padding(.horizontal, SettingsPageMetrics.sidePadding)
                .padding(.top, Theme.Spacing.xl + 2)
                .padding(.bottom, Theme.Spacing.l)
            PerchScroll {
                SettingsPageSections(page: page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ theme: Theme) -> some View {
        return HStack(alignment: .center, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .font(theme.font(size: 19, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A page's sections, stacked and padded the way the page frame shows them. Kept apart from the
/// frame so the height a page needs can be measured without a scroll view around it.
struct SettingsPageSections: View {
    let page: SettingsPageID

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsPageMetrics.sectionSpacing) {
            SettingsPageContent(page: page)
        }
        .padding(.horizontal, SettingsPageMetrics.sidePadding)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: SettingsPageMetrics.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Measurements shared by the page frame and views that line up with it.
enum SettingsPageMetrics {
    static let sidePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    /// Rows get hard to read when the window is made very wide, so the column stops growing here.
    static let maxContentWidth: CGFloat = 760
}
