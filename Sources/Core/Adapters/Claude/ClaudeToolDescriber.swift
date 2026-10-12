// ClaudeToolDescriber.swift — turns a Claude Code tool call into words a person can read.
//
// Claude Code reports every tool call as a tool name plus a bag of inputs that differs per tool
// ("Bash" has `command`, "Edit" has `file_path`, MCP tools have anything at all). The session
// cards and the approval cards need one short, plain line instead: "npm test",
// "Edit Sources/App/main.swift", "github → create_issue". Everything that knows about the
// individual tools' input shapes lives in this one file.

import Foundation

enum ClaudeToolDescriber {
    /// Longest one-line summary we hand to the views.
    static let summaryLimit = 120
    /// Longest "detail" text on an approval card (a whole shell command, a URL...).
    static let detailLimit = 4000

    // MARK: - Session cards: one short line per tool call

    /// A short description of a tool call, e.g. "npm test" or "Edit Sources/App/main.swift".
    static func summary(tool: String, input: JSONValue, cwd: String?) -> String {
        let text = rawSummary(tool: tool, input: input, cwd: cwd)
        return oneLine(text.isEmpty ? displayName(ofTool: tool) : text, limit: summaryLimit)
    }

    private static func rawSummary(tool: String, input: JSONValue, cwd: String?) -> String {
        func path(_ key: String) -> String? { input[key].stringValue.map { displayPath($0, cwd: cwd) } }
        switch tool {
        case "Bash":
            return input["command"].stringValue ?? input["description"].stringValue ?? "Run a shell command"
        case "BashOutput", "TaskOutput":
            return "Check on a background task"
        case "KillShell", "KillBash", "TaskStop":
            return "Stop a background task"
        case "Read":
            return "Read " + (path("file_path") ?? "a file")
        case "Edit", "MultiEdit":
            return "Edit " + (path("file_path") ?? "a file")
        case "Write":
            return "Write " + (path("file_path") ?? "a file")
        case "NotebookEdit":
            return "Edit notebook " + (path("notebook_path") ?? "")
        case "NotebookRead":
            return "Read notebook " + (path("notebook_path") ?? "")
        case "Grep":
            let pattern = input["pattern"].stringValue ?? ""
            let place = path("path") ?? input["glob"].stringValue
            return "Search for “\(pattern)”" + (place.map { " in \($0)" } ?? "")
        case "Glob":
            let pattern = input["pattern"].stringValue ?? ""
            return "Find files matching \(pattern)" + (path("path").map { " in \($0)" } ?? "")
        case "LS":
            return "List " + (path("path") ?? "a folder")
        case "WebFetch":
            let url = input["url"].stringValue ?? ""
            return "Fetch " + (host(of: url) ?? url)
        case "WebSearch":
            return "Search the web for “\(input["query"].stringValue ?? "")”"
        case "Task", "Agent":
            let kind = input["subagent_type"].stringValue ?? "Agent"
            let what = input["description"].stringValue ?? input["prompt"].stringValue ?? ""
            return what.isEmpty ? "Start a \(kind) subagent" : "\(kind): \(what)"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Update the to-do list"
        case "AskUserQuestion":
            let first = input["questions"][0]["question"].stringValue ?? ""
            return first.isEmpty ? "Ask you a question" : "Ask: \(first)"
        case "ExitPlanMode":
            return "Present a plan"
        case "EnterPlanMode":
            return "Start planning"
        case "Skill":
            let name = input["skill"].stringValue ?? input["command"].stringValue ?? ""
            return name.isEmpty ? "Use a skill" : "Use the \(name) skill"
        case "SlashCommand":
            return "Run " + (input["command"].stringValue ?? "a slash command")
        default:
            let name = displayName(ofTool: tool)
            guard let hint = primaryText(in: input) else { return name }
            return "\(name): \(hint)"
        }
    }

    // MARK: - Approval cards: what the tool wants to do, and the thing itself

    /// The two texts on an approval card. `summary` says what kind of thing is being asked
    /// ("Run a shell command"); `detail` is the thing itself (the command, the path, the URL).
    static func permissionText(tool: String, input: JSONValue, cwd: String?) -> (summary: String, detail: String) {
        func path(_ key: String) -> String { input[key].stringValue.map { displayPath($0, cwd: cwd) } ?? "" }
        let pair: (String, String)
        switch tool {
        case "Bash":
            pair = ("Run a shell command", input["command"].stringValue ?? "")
        case "Edit", "MultiEdit":
            pair = ("Edit a file", path("file_path"))
        case "Write":
            pair = ("Write a file", path("file_path"))
        case "NotebookEdit":
            pair = ("Edit a notebook", path("notebook_path"))
        case "Read":
            pair = ("Read a file", path("file_path"))
        case "Grep", "Glob":
            pair = ("Search files", input["pattern"].stringValue ?? "")
        case "LS":
            pair = ("List a folder", path("path"))
        case "WebFetch":
            pair = ("Fetch a web page", input["url"].stringValue ?? "")
        case "WebSearch":
            pair = ("Search the web", input["query"].stringValue ?? "")
        case "Task", "Agent":
            pair = ("Start a subagent", input["description"].stringValue ?? input["prompt"].stringValue ?? "")
        case "Skill":
            pair = ("Use a skill", input["skill"].stringValue ?? input["command"].stringValue ?? "")
        default:
            pair = ("Use " + displayName(ofTool: tool), compactJSON(input))
        }
        let detail = pair.1.isEmpty ? compactJSON(input) : pair.1
        return (pair.0, clip(detail, limit: detailLimit))
    }

    // MARK: - Names

    /// Splits "mcp__github__create_issue" into ("github", "create_issue"). Nil for built-in tools.
    static func mcpParts(_ tool: String) -> (server: String, tool: String)? {
        let prefix = "mcp__"
        guard tool.hasPrefix(prefix) else { return nil }
        let rest = tool.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return rest.isEmpty ? nil : (String(rest), "") }
        let server = String(rest[rest.startIndex..<separator.lowerBound])
        let name = String(rest[separator.upperBound...])
        return server.isEmpty ? nil : (server, name)
    }

    /// The tool's name as shown to people: MCP tools become "server → tool", the rest stay as they are.
    static func displayName(ofTool tool: String) -> String {
        guard let parts = mcpParts(tool) else { return tool.isEmpty ? "a tool" : tool }
        return parts.tool.isEmpty ? parts.server : "\(parts.server) → \(parts.tool)"
    }

    /// "claude-haiku-5-5" → "Haiku 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5",
    /// "claude-opus-4-1-20250805[1m]" → "Opus 4.1". Anything unrecognised is returned unchanged,
    /// so a new naming scheme shows the raw id rather than something wrong.
    static func modelDisplayName(_ id: String) -> String {
        var text = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = text.firstIndex(of: "[") { text = String(text[..<bracket]) }
        guard text.hasPrefix("claude-") else { return id }
        var family: String?
        var numbers: [String] = []
        for part in text.dropFirst("claude-".count).split(separator: "-") {
            if part.allSatisfy(\.isNumber) {
                // Short numbers are the version; a long one is the release date.
                if part.count <= 2 { numbers.append(String(part)) }
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = String(part)
            } else {
                return id
            }
        }
        guard let family, !numbers.isEmpty else { return id }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + numbers.joined(separator: ".")
    }

    // MARK: - Paths and text

    /// A path as short as it can be while staying unambiguous: relative to the session's folder
    /// when it is inside it, "~/..." when it is elsewhere in the home folder, otherwise unchanged.
    static func displayPath(_ path: String, cwd: String?, home: String = NSHomeDirectory()) -> String {
        func strip(_ base: String?) -> String? {
            guard var base, !base.isEmpty, base != "/" else { return nil }
            while base.count > 1, base.hasSuffix("/") { base.removeLast() }
            if path == base { return "" }
            return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
        }
        if let inside = strip(cwd) { return inside.isEmpty ? "." : inside }
        if let inside = strip(home) { return inside.isEmpty ? "~" : "~/" + inside }
        return path
    }

    /// The host of a URL, without "www." — "https://www.example.com/a?b" → "example.com".
    static func host(of urlString: String) -> String? {
        guard let host = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces))?.host, !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Collapses all runs of whitespace (including line breaks) into single spaces and caps the length.
    static func oneLine(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return clip(collapsed, limit: limit)
    }

    /// Cuts `text` to at most `limit` characters, ending in "…" when something was removed.
    static func clip(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// The tool input as one line of JSON, for tools we have no better description of.
    static func compactJSON(_ input: JSONValue) -> String {
        if input.isNull { return "" }
        if case .object(let members) = input, members.isEmpty { return "" }
        return input.serialized()
    }

    /// The most telling text field of an unknown tool's input, if it has an obvious one.
    private static func primaryText(in input: JSONValue) -> String? {
        for key in ["description", "command", "query", "prompt", "path", "file_path", "url", "name", "title"] {
            if let value = input[key].stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}
