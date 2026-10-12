// EmptyState.swift — the friendly "nothing here yet" block: a picture, a title, a sentence
// and (optionally) buttons.
//
//   PerchEmptyState(title: "No activity yet", message: "Events appear here as your agents work.",
//                   systemImage: "waveform.path.ecg")
//   PerchEmptyState(title: "No sessions yet", message: "...", mood: .idle) {
//       Button("Try demo mode") { ... }.buttonStyle(.perch(.primary))
//   }

import SwiftUI

struct PerchEmptyState<Actions: View>: View {
    private let title: String
    private let message: String
    private let mood: MascotMood
    private let systemImage: String?
    private let actions: Actions

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - mood: Mood of the mascot shown on top (used when `systemImage` is nil and the mascot is on).
    ///   - systemImage: An SF Symbol to show instead of the mascot.
    ///   - actions: Buttons shown under the message.
    init(title: String, message: String, mood: MascotMood = .idle, systemImage: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.mood = mood
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        let theme = Theme.current(settings)
        VStack(spacing: Theme.Spacing.m) {
            artwork(theme)
                .padding(.bottom, Theme.Spacing.xs)
            Text(title)
                .font(theme.font(.title))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(theme.font(.body))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            actions
                .padding(.top, Theme.Spacing.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.l)
    }

    @ViewBuilder
    private func artwork(_ theme: Theme) -> some View {
        let side = theme.scaled(56)
        ZStack {
            Circle().fill(RadialGradient(colors: [theme.accent.opacity(0.22), theme.accent.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: side * 0.7))
                .frame(width: side * 1.4, height: side * 1.4)
            Circle().fill(theme.surface).frame(width: side, height: side)
            Circle().strokeBorder(theme.stroke, lineWidth: 1).frame(width: side, height: side)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: side * 0.4, weight: .medium))
                    .foregroundStyle(theme.accentGradient)
            } else if settings.showMascot {
                MascotView(mood: mood, size: side * 0.6)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: side * 0.36, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

extension PerchEmptyState where Actions == EmptyView {
    init(title: String, message: String, mood: MascotMood = .idle, systemImage: String? = nil) {
        self.init(title: title, message: message, mood: mood, systemImage: systemImage) { EmptyView() }
    }
}
