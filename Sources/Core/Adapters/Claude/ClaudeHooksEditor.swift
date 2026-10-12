// ClaudeHooksEditor.swift — adds Perch's entries to, and removes them from, the "hooks" setting.
//
// The "hooks" value in settings.json looks like this:
//
//   "hooks": {
//     "PreToolUse": [                       ← one array per event
//       { "matcher": "Bash",                ← a "matcher group"
//         "hooks": [ { "type": "command", "command": "..." } ] },
//       ...
//     ]
//   }
//
// Other tools and the user put their own groups in the same arrays. These functions work on the
// parsed value only (no files), keep everything that is not ours in its place and order, and
// touch a group, an event array or the whole "hooks" object only where one of our entries is.

import Foundation

enum ClaudeHooksEditor {
    /// What is in the file compared with what Perch wants there.
    struct Inspection: Equatable {
        /// How many hook entries pointing at perch-hook exist, anywhere.
        var perchEntries = 0
        /// True when exactly the wanted entries are present, with the current command and options.
        var isComplete = false
    }

    static func inspect(hooks: ClaudeJSONNode?, wanted: [ClaudeHookPlan.Hook], helperPath: String) -> Inspection {
        var inspection = Inspection()
        guard let events = hooks?.members else { return inspection }
        var perEvent: [String: Int] = [:]
        for event in events {
            let count = (event.value.elements ?? []).reduce(0) { $0 + perchEntryCount(in: $1) }
            perEvent[event.key, default: 0] += count
            inspection.perchEntries += count
        }
        let allPresent = wanted.allSatisfy { hook in
            let expected = ClaudeHookPlan.group(for: hook, helperPath: helperPath)
            let groups = hooks?[hook.event]?.elements ?? []
            return perEvent[hook.event] == 1 && groups.contains { $0.jsonValue == expected.jsonValue }
        }
        inspection.isComplete = allPresent && inspection.perchEntries == wanted.count
        return inspection
    }

    /// Returns "hooks" with Perch's entries for `wanted` in place: any older entries of ours are
    /// taken out first (also from events we no longer use), then one group per event is appended.
    static func installing(into hooks: ClaudeJSONNode?, wanted: [ClaudeHookPlan.Hook], helperPath: String,
                           path: String) throws -> ClaudeJSONNode {
        var events = try removing(from: hooks, path: path).hooks?.members ?? []
        for hook in wanted {
            let group = ClaudeHookPlan.group(for: hook, helperPath: helperPath)
            if let index = events.lastIndex(where: { $0.key == hook.event }) {
                guard case .array(var groups) = events[index].value else {
                    throw ClaudeInstallError.unexpectedShape(path: path, problem: "its \"hooks.\(hook.event)\" setting is not a list")
                }
                groups.append(group)
                events[index].value = .array(groups)
            } else {
                events.append(ClaudeJSONMember(hook.event, .array([group])))
            }
        }
        return .object(events)
    }

    /// Returns "hooks" without any of Perch's entries (nil when nothing is left of it), and how
    /// many entries were removed. Groups, event arrays and the object itself are dropped only if
    /// removing our entry is what emptied them.
    static func removing(from hooks: ClaudeJSONNode?, path: String) throws -> (hooks: ClaudeJSONNode?, removed: Int) {
        guard let hooks else { return (nil, 0) }
        guard case .object(let events) = hooks else {
            throw ClaudeInstallError.unexpectedShape(path: path, problem: "its \"hooks\" setting is not an object")
        }
        var removed = 0
        var keptEvents: [ClaudeJSONMember] = []
        for event in events {
            guard case .array(let groups) = event.value else { keptEvents.append(event); continue }
            var keptGroups: [ClaudeJSONNode] = []
            var removedHere = 0
            for group in groups {
                let ours = perchEntryCount(in: group)
                guard ours > 0, case .object(var members) = group,
                      let hooksIndex = members.lastIndex(where: { $0.key == "hooks" }),
                      case .array(let entries) = members[hooksIndex].value else {
                    keptGroups.append(group)
                    continue
                }
                removedHere += ours
                let others = entries.filter { !isPerchEntry($0) }
                if !others.isEmpty {
                    // Someone put their hook in the same group as ours: keep the group for them.
                    members[hooksIndex].value = .array(others)
                    keptGroups.append(.object(members))
                }
            }
            removed += removedHere
            if removedHere == 0 || !keptGroups.isEmpty {
                keptEvents.append(ClaudeJSONMember(event.key, .array(keptGroups), rawKey: event.rawKey))
            }
        }
        if removed > 0, keptEvents.isEmpty { return (nil, removed) }
        return (.object(keptEvents), removed)
    }

    // MARK: - Recognising our entries

    private static func isPerchEntry(_ entry: ClaudeJSONNode) -> Bool {
        entry["command"]?.stringValue.map(ClaudeHookPlan.isPerchCommand) ?? false
    }

    private static func perchEntryCount(in group: ClaudeJSONNode) -> Int {
        (group["hooks"]?.elements ?? []).filter(isPerchEntry).count
    }
}
