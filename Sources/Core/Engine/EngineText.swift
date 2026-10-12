// EngineText.swift — small text helpers: session titles and safe clipping.
//
// A session's title is its first prompt, tidied up so it fits on one line of a card. Until a
// prompt arrives the title is the project folder's name.

import Foundation

enum EngineText {
    /// Turns a prompt into a card title: the first non-empty line, runs of white space collapsed,
    /// capped at about 80 characters. Returns nil when nothing usable is left, or when the text
    /// is a slash command ("/compact"), which says nothing about what the session is for.
    static func title(fromPrompt text: String, limit: Int = EngineTuning.titleLimit) -> String? {
        guard let line = firstLine(text), !line.hasPrefix("/") else { return nil }
        return clip(line, to: limit)
    }

    /// Tidies a title the agent supplied itself.
    static func title(fromAgent text: String?, limit: Int = EngineTuning.titleLimit) -> String? {
        guard let text, let line = firstLine(text) else { return nil }
        return clip(line, to: limit)
    }

    /// The title used before anything better is known.
    static func folderTitle(cwd: String, agent: AgentKind) -> String {
        let name = (cwd as NSString).lastPathComponent
        if !name.isEmpty && name != "/" { return name }
        return cwd.isEmpty ? agent.displayName : cwd
    }

    /// The first line that has something on it, with white space collapsed to single spaces.
    static func firstLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return nil
    }

    /// Cuts text to at most `limit` characters, ending in "…" when something was removed.
    static func clip(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Trims white space and caps the length; nil when nothing is left.
    static func tidy(_ text: String?, limit: Int = EngineTuning.textLimit) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return clip(trimmed, to: limit)
    }

    /// Cuts text to at most `limit` bytes of UTF-8 without splitting a character, and says so.
    static func clipBytes(_ text: String, to limit: Int = EngineTuning.rawLogLimit) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            kept.append(character)
            bytes += size
        }
        return kept + "\n… (cut short: \(total) bytes in all)"
    }
}
