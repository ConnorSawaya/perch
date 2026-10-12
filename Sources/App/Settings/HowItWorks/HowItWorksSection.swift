// HowItWorksSection.swift — the "How it works" part of Settings → Agents & help: a plain-English
// picture of what Perch does.
//
//   1. the live pipeline diagram (PipelineDiagram.swift): a dot runs along it for every event,
//   2. four short answers to the questions people ask (HowItWorksAnswers below),
//   3. a button that opens the one folder where Perch keeps its things.

import SwiftUI

struct HowItWorksSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @Environment(\.perchActions) private var actions
    @Environment(\.perchPipelineFreeze) private var freeze

    /// The run of light currently requested from the diagram.
    @State private var signal: PipelineSignal?

    var body: some View {
        let latest = sessions.activity.first

        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("How it works", systemImage: "lightbulb.fill") {
                Button {
                    actions.revealSupportFolder()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text("Reveal Perch's folder")
                    }
                }
                .buttonStyle(.perch(.secondary, size: .small))
                .help("Open the folder where Perch keeps its helper, backups, statistics and logs")
            }
            .padding(.horizontal, Theme.Spacing.xs)

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                PipelineDiagram(signal: freeze.map { PipelineSignal(id: UUID(), isReply: $0.isReply, startedAt: Date()) } ?? signal,
                                frozenProgress: freeze?.progress)
            }
            .padding(SettingsRowMetrics.sidePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground())
        }
        .onChange(of: latest?.id) { _, _ in
            // Notes (such as "hooks installed") are Perch talking to itself; nothing travelled.
            guard let latest, latest.direction != .note else { return }
            signal = PipelineSignal(id: latest.id, isReply: latest.direction == .outgoing, startedAt: Date())
        }
    }

    /// The answers, two to a line.
    private var answers: some View {
        let all = HowItWorksAnswers.all
        return Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.xxl, verticalSpacing: Theme.Spacing.l) {
            ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { first in
                GridRow {
                    ForEach(all[first..<min(first + 2, all.count)]) { answer in
                        HowItWorksAnswerCell(answer: answer)
                    }
                }
            }
        }
    }
}

// MARK: - Freezing the diagram for pictures

/// A moment of the diagram's animation to draw instead of the live one (snapshots only).
struct PipelineFreeze: Equatable {
    var progress: Double
    var isReply: Bool
}

private struct PipelineFreezeKey: EnvironmentKey {
    static let defaultValue: PipelineFreeze? = nil
}

extension EnvironmentValues {
    /// When set, the "How it works" diagram is drawn stopped at this moment. The app never sets it.
    var perchPipelineFreeze: PipelineFreeze? {
        get { self[PipelineFreezeKey.self] }
        set { self[PipelineFreezeKey.self] = newValue }
    }
}

// MARK: - The answers

/// One question and its plain-English answer.
struct HowItWorksAnswer: Identifiable {
    let id: Int
    let question: String
    let answer: String
}

enum HowItWorksAnswers {
    /// Each must stay true of the whole app, and short enough to read at a glance.
    static let all: [HowItWorksAnswer] = [
        HowItWorksAnswer(id: 0, question: "What is a hook?",
                         answer: "A small program your agent runs whenever something happens. Connect adds Perch's "
                            + "helper, perch-hook, to that list."),
        HowItWorksAnswer(id: 1, question: "What happens when an agent asks permission?",
                         answer: "It runs the hook and waits. The notch shows the request, and your Allow or Deny "
                            + "travels back the same way."),
        HowItWorksAnswer(id: 2, question: "What does Perch see?",
                         answer: "Only what agents tell their hooks, and files they keep on this Mac. No network, "
                            + "no account, no logins."),
        HowItWorksAnswer(id: 3, question: "What if Perch is closed, or breaks?",
                         answer: "The helper exits at once and your agent carries on exactly as if Perch were "
                            + "not installed."),
    ]
}

/// A question in bold with its answer underneath.
private struct HowItWorksAnswerCell: View {
    let answer: HowItWorksAnswer

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 2) {
            Text(answer.question)
                .font(theme.font(.label))
                .foregroundStyle(theme.textPrimary)
            Text(answer.answer)
                .font(theme.font(.caption))
                .foregroundStyle(SettingsRowMetrics.explanationColor(theme))
                .lineSpacing(1.5)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
