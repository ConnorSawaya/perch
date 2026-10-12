-- Perch reference: focus the Terminal.app tab that owns a TTY.
-- Usage: osascript terminal-app-jump.applescript /dev/ttys003
-- Every term used here was checked against
--   /System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.sdef
-- (Terminal 2.15, macOS 26.6) and this file compiles with `osacompile` on that machine.
-- It was compiled only, never run, during research.
--
-- Do NOT name a local variable `tty`: it shadows the tab property and the comparison
-- silently matches the wrong tab (CodeIsland issue #124).
-- A window can have no tabs at all (invisible utility window); `tabs of w` then raises
-- -10000, so that access sits in its own `try` (CodeIsland issue #294).
-- `tab` has no `name` and no working-directory property in this dictionary.
on run argv
	set targetTty to item 1 of argv
	tell application "Terminal"
		set found to false
		repeat with w in windows
			try
				repeat with t in tabs of w
					try
						if tty of t is targetTty then
							if miniaturized of w then set miniaturized of w to false
							set selected tab of w to t
							set frontmost of w to true
							set index of w to 1
							set found to true
							exit repeat
						end if
					end try
				end repeat
			end try
			if found then exit repeat
		end repeat
		if found then activate
		return found
	end tell
end run
