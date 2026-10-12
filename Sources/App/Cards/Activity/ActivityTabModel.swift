// ActivityTabModel.swift — filtering and wording for the Activity tab (pure, no UI).
//
// The activity log (SessionStore.activity) is a list of everything that passed between the
// agents and Perch, newest first. This file decides which entries a filter lets through, which
// agents can be filtered on, and how an entry's time and raw JSON are shown.

import Foundation

struct ActivityTabFilter: Equatable {
    /// The agent to show, as the lower-case name stored in the log ("claude"); nil shows every agent.
    var agent: String?
    /// The direction to show; nil shows all three.
    var direction: ActivityEntry.Direction?

    var isActive: Bool { agent != nil || direction != nil }

    func matches(_ entry: ActivityEntry) -> Bool {
        if let agent, Self.key(entry.agent) != agent { return false }
        if let direction, entry.direction != direction { return false }
        return true
    }

    func apply(to entries: [ActivityEntry]) -> [ActivityEntry] {
        isActive ? entries.filter(matches) : entries
    }

    /// The agents that appear in the log, known agents first in their usual order, then any
    /// others alphabetically. Entries with no agent (Perch's own notes) are not listed.
    static func agents(in entries: [ActivityEntry]) -> [String] {
        let present = Set(entries.map { key($0.agent) }).subtracting([""])
        let known = AgentKind.allCases.map(\.rawValue).filter(present.contains)
        return known + present.subtracting(known).sorted()
    }

    /// The name to show for a filter key: the agent's name as the log spelled it.
    static func label(for agent: String, in entries: [ActivityEntry]) -> String {
        let spelled = entries.first { key($0.agent) == agent }?.agent ?? agent
        return ActivityTabWording.shortAgentName(spelled)
    }

    static func key(_ agent: String) -> String {
        agent.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

enum ActivityTabWording {
    /// A short name for an agent as stored in the log: "claude" → "Claude", "gemini" → "Gemini".
    static func shortAgentName(_ raw: String) -> String {
        let name = CardsWording.agentName(raw)
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    static func symbol(_ direction: ActivityEntry.Direction) -> String {
        switch direction {
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        case .note: return "text.alignleft"
        }
    }

    /// What a direction means, for tooltips and VoiceOver.
    static func meaning(_ direction: ActivityEntry.Direction) -> String {
        switch direction {
        case .incoming: return "Came in from the agent"
        case .outgoing: return "Sent back by Perch"
        case .note: return "A note from Perch itself"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "9:41:07 AM" for today's entries; older ones also say which day.
    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? timeFormatter.string(from: date)
            : "\(dayFormatter.string(from: date)), \(shortTimeFormatter.string(from: date))"
    }

    /// The entry's raw JSON laid out over several lines. Text that is not valid JSON (it may have
    /// been cut short) is returned as it is; nil means there is nothing to show.
    static func prettyRaw(_ raw: String) -> String? {
        guard let text = CardsWording.tidy(raw) else { return nil }
        return JSONValue.parse(text)?.serialized(pretty: true) ?? text
    }
}
