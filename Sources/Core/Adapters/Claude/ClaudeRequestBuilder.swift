// ClaudeRequestBuilder.swift — turns a Claude Code "PermissionRequest" into what a card shows.
//
// Claude Code fires one event, PermissionRequest, for three different situations:
//   - an ordinary permission prompt ("may I run this command / edit this file?"),
//   - a multiple-choice question for the user (the tool is called AskUserQuestion),
//   - a finished plan waiting for approval (the tool is called ExitPlanMode).
// This file reads the tool's input and builds the matching PermissionRequest, QuestionRequest or
// PlanRequest, including the "always allow" choices with plain-English labels.

import Foundation

enum ClaudeRequestBuilder {
    static let questionTool = "AskUserQuestion"
    static let planTool = "ExitPlanMode"

    /// The event for a PermissionRequest payload.
    static func event(tool: String, input: JSONValue, suggestions: JSONValue, cwd: String?) -> AgentEvent {
        if tool == questionTool, let request = questionRequest(input) { return .questionAsked(request) }
        if tool == planTool, let plan = input["plan"].stringValue {
            return .planProposed(PlanRequest(markdown: plan, filePath: input["planFilePath"].stringValue))
        }
        return .permissionRequested(permissionRequest(tool: tool, input: input, suggestions: suggestions, cwd: cwd))
    }

    // MARK: - Questions

    /// Reads AskUserQuestion's input. Nil when there is no usable question in it.
    static func questionRequest(_ input: JSONValue) -> QuestionRequest? {
        var questions: [Question] = []
        for item in input["questions"].arrayValue ?? [] {
            guard let text = item["question"].stringValue, !text.isEmpty else { continue }
            var options: [QuestionOption] = []
            for option in item["options"].arrayValue ?? [] {
                // Options are objects with a label; tolerate a bare string as well.
                guard let label = option["label"].stringValue ?? option.stringValue, !label.isEmpty else { continue }
                options.append(QuestionOption(id: options.count, label: label, detail: nonEmpty(option["description"].stringValue)))
            }
            questions.append(Question(id: questions.count, text: text, header: nonEmpty(item["header"].stringValue),
                                      options: options, multiSelect: item["multiSelect"].boolValue ?? false))
        }
        return questions.isEmpty ? nil : QuestionRequest(questions: questions)
    }

    // MARK: - Permission prompts

    static func permissionRequest(tool: String, input: JSONValue, suggestions: JSONValue, cwd: String?) -> PermissionRequest {
        let text = ClaudeToolDescriber.permissionText(tool: tool, input: input, cwd: cwd)
        let dangerous = tool == "Bash" && ClaudeDangerDetector.isDangerous(input["command"].stringValue ?? "")
        var offered: [PermissionSuggestion] = []
        for raw in suggestions.arrayValue ?? [] {
            offered.append(PermissionSuggestion(id: offered.count, label: label(forSuggestion: raw, cwd: cwd), raw: raw))
        }
        // Claude Code does not always send suggestions. A rule we write ourselves is accepted too
        // (observed live), so offer one narrow, session-only choice — but never for a risky command.
        if offered.isEmpty, !dangerous, let own = sessionRule(tool: tool, input: input) {
            offered.append(PermissionSuggestion(id: 0, label: label(forSuggestion: own, cwd: cwd), raw: own))
        }
        return PermissionRequest(toolName: tool, summary: text.summary, detail: text.detail,
                                 diff: ClaudeDiffBuilder.preview(tool: tool, input: input, cwd: cwd),
                                 suggestions: offered, isDangerous: dangerous)
    }

    /// A rule that allows exactly this kind of call until the session ends.
    /// Bash: this exact command. WebFetch: this site. Other tools: the tool itself.
    static func sessionRule(tool: String, input: JSONValue) -> JSONValue? {
        guard !tool.isEmpty, tool != questionTool, tool != planTool else { return nil }
        var rule: [String: JSONValue] = ["toolName": .string(tool)]
        switch tool {
        case "Bash":
            guard let command = input["command"].stringValue, !command.isEmpty, !command.contains("\n") else { return nil }
            rule["ruleContent"] = .string(command)
        case "WebFetch":
            // The exact host, "www." included: the rule has to match what Claude Code compares against.
            guard let host = URLComponents(string: input["url"].stringValue ?? "")?.host, !host.isEmpty else { return nil }
            rule["ruleContent"] = .string("domain:" + host)
        default:
            break   // MCP tools in particular must not carry ruleContent, or the rule never matches
        }
        return ["type": "addRules", "rules": .array([.object(rule)]), "behavior": "allow", "destination": "session"]
    }

    // MARK: - Labels for "always allow" choices

    /// A plain-English label for one of Claude Code's permission suggestions. The suggestion may
    /// add rules, switch the permission mode or open up a folder, so the label covers each kind.
    static func label(forSuggestion suggestion: JSONValue, cwd: String?) -> String {
        let scope = scopePhrase(suggestion["destination"].stringValue)
        switch suggestion["type"].stringValue ?? "" {
        case "addRules", "replaceRules":
            let rules = ruleList(suggestion["rules"])
            switch suggestion["behavior"].stringValue ?? "allow" {
            case "deny": return "Always refuse \(rules)\(scope)"
            case "ask": return "Always ask before \(rules)\(scope)"
            default: return "Always allow \(rules)\(scope)"
            }
        case "removeRules":
            return "Remove the rule for \(ruleList(suggestion["rules"]))\(scope)"
        case "setMode":
            switch suggestion["mode"].stringValue ?? "" {
            case "acceptEdits": return "Allow all file edits\(scope)"
            case "bypassPermissions": return "Stop asking for any permission\(scope)"
            case "plan": return "Switch to plan mode\(scope)"
            case "auto": return "Switch to auto mode\(scope)"
            case "default", "manual": return "Go back to asking every time\(scope)"
            case let other: return "Switch to \(other.isEmpty ? "another" : other) mode\(scope)"
            }
        case "addDirectories":
            return "Allow working in \(folderList(suggestion["directories"], cwd: cwd))\(scope)"
        case "removeDirectories":
            return "Stop working in \(folderList(suggestion["directories"], cwd: cwd))\(scope)"
        case let other:
            return "Apply Claude's suggested change\(other.isEmpty ? "" : " (\(other))")\(scope)"
        }
    }

    /// Where a permission change is remembered, in plain words (with a leading space).
    private static func scopePhrase(_ destination: String?) -> String {
        switch destination ?? "" {
        case "session": return " for this session"
        case "localSettings": return " in this project"
        case "projectSettings": return " in this project, for everyone who uses it"
        case "userSettings": return " in all your projects"
        default: return ""
        }
    }

    private static func ruleList(_ rules: JSONValue) -> String {
        let names: [String] = (rules.arrayValue ?? []).map { rule in
            let tool = rule["toolName"].stringValue ?? ""
            let content = rule["ruleContent"].stringValue ?? ""
            if content.isEmpty { return ClaudeToolDescriber.displayName(ofTool: tool) }
            let shown = "`" + ClaudeToolDescriber.oneLine(content, limit: 60) + "`"
            return tool == "Bash" || tool.isEmpty ? shown : "\(ClaudeToolDescriber.displayName(ofTool: tool)) \(shown)"
        }
        return list(names, empty: "this")
    }

    private static func folderList(_ directories: JSONValue, cwd: String?) -> String {
        let names: [String] = (directories.arrayValue ?? []).compactMap { $0.stringValue }.map { path in
            let name = (path as NSString).lastPathComponent
            return path == cwd ? "this folder (\(name))" : (name.isEmpty ? path : name)
        }
        return list(names, empty: "more folders")
    }

    /// "a", "a and b", "a, b and 2 more".
    private static func list(_ names: [String], empty: String) -> String {
        switch names.count {
        case 0: return empty
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
