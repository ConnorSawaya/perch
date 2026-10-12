-- Perch reference: which TTY is the user looking at in Terminal.app?
-- Returns "" when there is no front window. Compare with the session's TTY to decide
-- whether a sound / auto-expand should be suppressed.
-- Terms validated against Terminal.sdef (Terminal 2.15, macOS 26.6); compiled only, never run.
tell application "Terminal"
	try
		return tty of selected tab of front window
	end try
	return ""
end tell
