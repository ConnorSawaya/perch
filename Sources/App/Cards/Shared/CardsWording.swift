// CardsWording.swift — the small word and icon choices the cards share.
//
// Pure functions: data in, words out. Keeping them in one place means the approval card, the
// activity log and the usage tab describe the same thing the same way.

import Foundation

enum CardsWording {
    /// The text without surrounding spaces, or nil when nothing readable is left.
    static func tidy(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// An SF Symbol for a tool, guessed from its name. Unknown tools get a generic wrench.
    static func toolSymbol(_ toolName: String) -> String {
        let name = toolName.lowercased()
        // Tools from extensions can be called anything ("…_review" is not a "view"), so they
        // get one symbol of their own instead of a guess.
        if name.hasPrefix("mcp__") { return "puzzlepiece.extension.fill" }
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("bash", "shell", "exec", "command", "terminal") { return "terminal.fill" }
        if has("edit", "write", "patch", "replace", "notebook") { return "pencil" }
        if has("web", "fetch", "browser", "http") { return "globe" }
        if has("grep", "glob", "search", "find") || name == "ls" { return "magnifyingglass" }
        if has("read") || name == "view" || name == "cat" { return "doc.text" }
        if has("task", "agent") { return "person.2.fill" }
        if has("todo", "plan") { return "checklist" }
        return "wrench.and.screwdriver.fill"
    }

    /// A tool name short enough for a small label. Tools from extensions arrive as
    /// "mcp__server__tool"; only the tool's own name is kept (the card's title names the
    /// extension). Anything still too long is cut.
    static func shortToolName(_ toolName: String) -> String {
        var name = toolName
        if name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last(where: { !$0.isEmpty }) {
            name = tool
        }
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }

    /// Where a request came from, for the line under a card's title:
    /// "sightsense · Clean up the build folder and rerun tests".
    /// With `fullPath` (the "Show project path" setting) the folder is shown as "~/code/sightsense".
    static func origin(of request: PendingRequest, session: Session?, fullPath: Bool = false) -> String {
        guard let session else { return request.agent.displayName }
        let name = tidy(session.projectName)
        let folder = fullPath ? (tidy(session.cwd).map(PerchFormat.path) ?? name) : name
        let title = tidy(session.title)
        // Until the first prompt arrives the title is just the folder name; do not say it twice.
        let parts = [folder, title == name ? nil : title].compactMap { $0 }
        return parts.isEmpty ? request.agent.displayName : parts.joined(separator: " · ")
    }

    /// A readable name for the agent string stored in the activity log ("claude" → "Claude Code").
    static func agentName(_ raw: String) -> String {
        if let known = AgentKind(rawValue: raw.lowercased()) { return known.displayName }
        return tidy(raw).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Perch"
    }

    /// "1 line", "3 lines" — a count with the right noun form.
    static func counted(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : (plural ?? singular + "s"))
    }
}
