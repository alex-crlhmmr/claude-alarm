-- Focus the terminal Claude is actually running in.
--
-- Launched by clicking a notification: claude-notify can only activate an app
-- on click, not run a command, so it activates this app and this app does the
-- work. alarm.sh leaves the details in .alarm-state/focus-target as key=value:
--
--   bundle=com.apple.Terminal
--   tty=/dev/ttys007
--   cwd=/Users/you/project
--
-- Terminal.app is scriptable, so its tab is matched exactly on tty.
-- VS Code has no AppleScript dictionary at all, so its window is raised through
-- the Accessibility API instead, matched on the folder name in the title. That
-- needs Accessibility permission; without it the app is merely activated.

on valueFor(k, ls)
	repeat with ln in ls
		set l to ln as string
		if l starts with (k & "=") then
			-- Guard the empty value. "text 5 thru -1 of \"tty=\"" is an error,
			-- not an empty string, and an unguarded slice threw before the
			-- script ever reached the branch that did not need that key.
			if (length of l) is less than or equal to ((length of k) + 1) then return ""
			return text ((length of k) + 2) thru -1 of l
		end if
	end repeat
	return ""
end valueFor

on run
	set f to (POSIX path of (path to home folder)) & ".claude/hooks/.alarm-state/focus-target"
	set raw to ""
	try
		set raw to do shell script "cat " & quoted form of f
	end try
	if raw is "" then return

	-- "paragraphs of", not splitting on linefeed: do shell script hands back
	-- text with carriage returns, so a linefeed split silently returns the whole
	-- file as one item and every lookup but the first comes back empty.
	set ls to paragraphs of raw

	set theBundle to valueFor("bundle", ls)
	set theTty to valueFor("tty", ls)
	set theCwd to valueFor("cwd", ls)

	if theBundle is "com.apple.Terminal" then
		focusTerminalTab(theTty)
	else
		focusWindowByTitle(theBundle, theCwd)
	end if
end run

on focusTerminalTab(theTty)
	tell application "Terminal"
		activate
		if theTty is "" then return
		repeat with w from 1 to count of windows
			repeat with t from 1 to count of tabs of window w
				if (tty of tab t of window w) is theTty then
					set selected tab of window w to tab t of window w
					-- "set index to 1" only reorders AppleScript's own window
					-- list; it does not raise the window on screen, which lands
					-- you on whatever was visually on top. frontmost raises it.
					set frontmost of window w to true
					return
				end if
			end repeat
		end repeat
	end tell
end focusTerminalTab

-- For apps with no AppleScript dictionary. Activating alone restores whatever
-- window was last focused, which is the wrong one whenever Claude sits in a
-- background window, so the matching window is raised explicitly.
--
-- Only the window is addressable. Which pane or integrated terminal has focus
-- inside it is not exposed by any interface outside the editor.
on focusWindowByTitle(theBundle, theCwd)
	if theBundle is "" then return

	-- Activate first: it is the useful fallback if Accessibility is refused,
	-- and it costs nothing when the raise below succeeds.
	try
		do shell script "open -b " & quoted form of theBundle
	end try
	if theCwd is "" then return

	set folderName to ""
	try
		set AppleScript's text item delimiters to "/"
		set parts to text items of theCwd
		set AppleScript's text item delimiters to ""
		repeat with i from (count of parts) to 1 by -1
			if (item i of parts) is not "" then
				set folderName to item i of parts
				exit repeat
			end if
		end repeat
	end try
	if folderName is "" then return

	try
		tell application "System Events"
			set procs to (every process whose bundle identifier is theBundle)
			if procs is {} then return
			set p to item 1 of procs
			repeat with w in windows of p
				set nm to ""
				try
					set nm to name of w
				end try
				if nm contains folderName then
					perform action "AXRaise" of w
					set frontmost of p to true
					return
				end if
			end repeat
		end tell
	on error
		-- No Accessibility permission. The activate above already ran, so the
		-- click still takes you to the app, just not to a specific window.
		return
	end try
end focusWindowByTitle
