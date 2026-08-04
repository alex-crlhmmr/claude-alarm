on run
	set ttyFile to (POSIX path of (path to home folder)) & ".claude/hooks/.alarm-state/focus-tty"
	set targetTty to ""
	try
		set targetTty to do shell script "cat " & quoted form of ttyFile
	end try
	tell application "Terminal"
		activate
		if targetTty is not "" then
			repeat with w from 1 to count of windows
				repeat with t from 1 to count of tabs of window w
					if (tty of tab t of window w) is targetTty then
						set selected tab of window w to tab t of window w
						-- "set index to 1" only reorders AppleScript's own list; it
						-- does not raise the window on screen, which lands you on
						-- whatever was visually on top instead. frontmost raises it.
						set frontmost of window w to true
						return
					end if
				end repeat
			end repeat
		end if
	end tell
end run
