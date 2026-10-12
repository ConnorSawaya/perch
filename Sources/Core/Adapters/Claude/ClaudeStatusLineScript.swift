// ClaudeStatusLineScript.swift — the small shell script Perch puts in front of the status line.
//
// Claude Code gives its status line command a JSON object with the model, context use and the
// 5-hour / weekly limits. That is the only place those limits can be read without credentials,
// and only one status line command can be configured. So Perch chains instead of replacing:
// its script passes a copy of the JSON to `perch-hook` in the background and then runs the
// user's own command exactly as before. If the user had no status line, the script prints a
// small one of its own (model · folder · context used).
//
// How the script stays out of the way (docs/research/claude-usage.md §6.4):
//   - stdin is read once and the same text is given to both consumers;
//   - the copy for Perch is sent by a background job whose output goes to /dev/null, so it adds
//     no waiting and can never print into the status line;
//   - the user's command runs last, in the foreground: its output is the status line and its
//     exit status is the script's.
//
// The script also carries the user's original setting in a comment, so it can be restored even
// if Perch's own record of it (ClaudeInstallRecord) is lost.

import Foundation

enum ClaudeStatusLineScript {
    static let fileName = "perch-statusline.sh"
    /// Bump when the script's text changes in a way that matters, so old copies are rewritten.
    static let version = 2
    private static let originalMarker = "# perch-original-statusline: "

    /// The "command" written into settings.json. Run through /bin/sh so the script does not
    /// depend on its executable bit surviving.
    static func command(scriptPath: String) -> String {
        "/bin/sh " + ClaudeHookPlan.shellQuote(scriptPath)
    }

    /// True for a status line command that runs a Perch script (at any path).
    static func isPerchCommand(_ command: String) -> Bool { command.contains(fileName) }

    /// The script's text.
    /// - `originalCommand`: the user's own status line command, or nil if they had none.
    /// - `originalSetting`: their whole "statusLine" value as JSON text, kept for restoring.
    static func script(helperPath: String, originalCommand: String?, originalSetting: String?) -> String {
        let saved = originalSetting.map { Data($0.utf8).base64EncodedString() } ?? "none"
        var lines = [
            "#!/bin/sh",
            "# Perch status line script (version \(version)). Written by Perch; removed when you uninstall its hooks.",
            "# It gives Perch a copy of Claude Code's status line data, then shows your status line as before.",
            originalMarker + saved,
            "input=$(cat)",
            "helper=\(ClaudeHookPlan.shellQuote(helperPath))",
            "if [ -x \"$helper\" ]; then",
            "  ( printf '%s' \"$input\" | \"$helper\" --agent claude --channel statusline ) >/dev/null 2>&1 </dev/null &",
            "fi",
        ]
        if let originalCommand {
            lines += [
                "original=\(ClaudeHookPlan.shellQuote(originalCommand))",
                "printf '%s' \"$input\" | /bin/sh -c \"$original\"",
            ]
        } else {
            lines += defaultStatusLine
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the user's original "statusLine" JSON back out of a script written by `script`.
    /// Nil when the script records that there was none, or is not one of ours.
    static func originalSetting(inScript text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix(originalMarker) {
            let encoded = String(line.dropFirst(originalMarker.count)).trimmingCharacters(in: .whitespaces)
            guard encoded != "none", let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// A status line for people who had none: "Haiku 5.5 · my-project · 12% context".
    /// Plain POSIX shell with no helper programs (no jq, no sed), so it costs next to nothing.
    /// It reads three values straight out of the JSON text; anything missing is simply left out.
    private static let defaultStatusLine: [String] = [
        "# Prints the text value that follows the first \"key\" in $2.",
        "text_after() {",
        "  rest=${2#*\\\"$1\\\"}",
        "  [ \"$rest\" = \"$2\" ] && return 0",
        "  rest=${rest#*:}",
        "  rest=${rest#\"${rest%%[![:space:]]*}\"}",
        "  case $rest in",
        "    \\\"*) rest=${rest#\\\"}; printf '%s' \"${rest%%\\\"*}\" ;;",
        "  esac",
        "}",
        "# Prints the whole-number part of the number that follows the first \"key\" in $2.",
        "number_after() {",
        "  rest=${2#*\\\"$1\\\"}",
        "  [ \"$rest\" = \"$2\" ] && return 0",
        "  rest=${rest#*:}",
        "  rest=${rest#\"${rest%%[![:space:]]*}\"}",
        "  case $rest in",
        "    [0-9]*) printf '%s' \"${rest%%[!0-9]*}\" ;;",
        "  esac",
        "}",
        "model=$(text_after display_name \"$input\")",
        "folder=$(text_after current_dir \"$input\")",
        "[ -n \"$folder\" ] || folder=$(text_after cwd \"$input\")",
        "folder=${folder##*/}",
        "# \"used_percentage\" also appears under the rate limits; the one after \"context_window\" is the context.",
        "context=${input#*\\\"context_window\\\"}",
        "used=''",
        "[ \"$context\" = \"$input\" ] || used=$(number_after used_percentage \"$context\")",
        "line=$model",
        "[ -n \"$folder\" ] && line=\"${line:+$line · }$folder\"",
        "[ -n \"$used\" ] && line=\"${line:+$line · }$used% context\"",
        "printf '%s' \"$line\"",
        "exit 0",
    ]
}

/// What Perch remembers about an install, saved next to the helper. It is what makes uninstall
/// exact: the user's original status line setting, and whether the settings file was ours to begin with.
struct ClaudeInstallRecord: Codable, Equatable {
    static let fileName = "claude-install.json"

    /// The settings file this record is about.
    var settingsPath: String
    /// True when there was no settings.json before Perch installed (so an empty one can go again).
    var createdSettingsFile: Bool
    /// The user's "statusLine" value exactly as it was written in the file; nil if they had none.
    var originalStatusLine: String?
    /// False when Perch decided not to touch the status line (it was not a plain command).
    var managesStatusLine: Bool
    var installedAt: Date

    static func load(from url: URL) -> ClaudeInstallRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeInstallRecord.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
