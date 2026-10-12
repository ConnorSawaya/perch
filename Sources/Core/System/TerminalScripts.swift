// TerminalScripts.swift — builds the AppleScript we send to Terminal, iTerm2 and Ghostty.
//
// These are pure functions from values to script text, so the exact scripts can be unit-tested.
// Values that come from outside (a TTY, a session id, a folder) are DATA: they are only ever
// placed inside a quoted AppleScript string by `AppleScriptText.literal`, which escapes
// everything that could end the string early. They are never pasted in as code.
//
// Every script answers with one of the words in `TerminalScripts.Answer` so the caller can report
// honestly whether the exact tab was found.
//
// Lessons from other apps that are baked in here:
// - never name a variable `tty`: it hides the tab property and the comparison goes wrong;
// - a window can have no tabs (a hidden utility window), which raises an error, so each window is
//   handled inside its own `try`;
// - apps are addressed by bundle id, so a renamed app cannot make the script ask "Where is …?".

import Foundation

enum AppleScriptText {
    /// `value` as an AppleScript string literal, quotes included.
    static func literal(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Other control characters have no place in a path or an id; leave them out.
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

enum TerminalScripts {

    /// The words our scripts return.
    enum Answer {
        /// The exact tab / session was brought forward.
        static let focused = "focused"
        /// Several candidates matched; one of them was brought forward.
        static let ambiguous = "ambiguous"
        /// Nothing matched.
        static let missing = "missing"
    }

    // MARK: Terminal.app
    // Terms checked against Terminal.sdef: window has `tabs`, `selected tab`, `frontmost`, `index`,
    // `miniaturized`; tab has `tty`. A tab has no name and no working directory.

    /// Selects the tab whose TTY is `tty` and brings its window to the front.
    static func terminalJump(tty: String, bundleID: String = TerminalKind.BundleIDs.appleTerminal) -> String {
        """
        tell application id \(AppleScriptText.literal(bundleID))
        	set wantedDevice to \(AppleScriptText.literal(tty))
        	repeat with w in windows
        		try
        			repeat with t in tabs of w
        				if (tty of t) is wantedDevice then
        					if miniaturized of w then set miniaturized of w to false
        					set selected tab of w to t
        					set frontmost of w to true
        					set index of w to 1
        					activate
        					return "\(Answer.focused)"
        				end if
        			end repeat
        		end try
        	end repeat
        	return "\(Answer.missing)"
        end tell
        """
    }

    /// Returns the TTY of the tab the user is looking at ("" when there is no window).
    static func terminalFrontTTY(bundleID: String = TerminalKind.BundleIDs.appleTerminal) -> String {
        """
        tell application id \(AppleScriptText.literal(bundleID))
        	try
        		return tty of selected tab of front window
        	end try
        	return ""
        end tell
        """
    }

    // MARK: iTerm2
    // From iTerm2's scripting dictionary: window has `tabs`, `current tab`, `current session`,
    // `miniaturized`; tab has `sessions`, `current session`; session has `tty` and `unique ID`;
    // windows, tabs and sessions all understand `select`. Selecting the window is what makes
    // macOS switch Space for a full-screen window.

    /// Selects the session with this unique id or this TTY (either may be nil, not both).
    static func iTermJump(sessionGUID: String?, tty: String?, bundleID: String = TerminalKind.BundleIDs.iTerm) -> String {
        """
        tell application id \(AppleScriptText.literal(bundleID))
        	set wantedID to \(AppleScriptText.literal(sessionGUID ?? ""))
        	set wantedDevice to \(AppleScriptText.literal(tty ?? ""))
        	repeat with w in windows
        		try
        			repeat with t in tabs of w
        				repeat with s in sessions of t
        					set isMatch to false
        					if wantedID is not "" and (unique ID of s) is wantedID then set isMatch to true
        					if wantedDevice is not "" and (tty of s) is wantedDevice then set isMatch to true
        					if isMatch then
        						if miniaturized of w then set miniaturized of w to false
        						tell w to select
        						tell t to select
        						tell s to select
        						activate
        						return "\(Answer.focused)"
        					end if
        				end repeat
        			end repeat
        		end try
        	end repeat
        	return "\(Answer.missing)"
        end tell
        """
    }

    /// Returns the TTY of the session that has keyboard focus ("" when there is no window).
    static func iTermFrontTTY(bundleID: String = TerminalKind.BundleIDs.iTerm) -> String {
        """
        tell application id \(AppleScriptText.literal(bundleID))
        	try
        		return tty of current session of current window
        	end try
        	return ""
        end tell
        """
    }

    // MARK: Ghostty
    // Ghostty (1.3 and later) has `terminal` objects with a `working directory`, and a `focus`
    // command. It does not expose a TTY, so the folder is the best match available. `focus` must
    // come before `activate`: activating first pops up Ghostty's quick terminal.

    /// Focuses the terminal whose working directory is `folder`.
    static func ghosttyJump(folder: String, bundleID: String = TerminalKind.BundleIDs.ghostty) -> String {
        """
        tell application id \(AppleScriptText.literal(bundleID))
        	set wantedFolder to \(AppleScriptText.literal(folder))
        	set found to every terminal whose working directory is wantedFolder
        	if (count of found) is 0 then return "\(Answer.missing)"
        	focus (item 1 of found)
        	activate
        	if (count of found) is 1 then return "\(Answer.focused)"
        	return "\(Answer.ambiguous)"
        end tell
        """
    }
}
