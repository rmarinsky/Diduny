-- Accessibility smoke test for the Diduny DEV unified window.
-- Requires Accessibility permission for the runner (Terminal/Codex).
--
-- Optional destructive/paid-action probes are disabled by default:
--   DIDUNY_UI_SMOKE_TRANSCRIBE=1 osascript scripts/diduny-ui-smoke.applescript
--   DIDUNY_UI_SMOKE_DELETE=1 osascript scripts/diduny-ui-smoke.applescript

property appName : "Diduny DEV"
property windowTitle : "Diduny"

on envFlag(flagName)
	try
		set rawValue to do shell script "printenv " & quoted form of flagName
		return rawValue is "1" or rawValue is "true"
	on error
		return false
	end try
end envFlag

on waitForMainWindow()
	tell application "System Events"
		repeat with i from 1 to 40
			if my mainWindowExists() then return true
			delay 0.25
		end repeat
	end tell
	error "Diduny main window did not appear"
end waitForMainWindow

on mainWindowExists()
	tell application "System Events"
		if exists process appName then
			tell process appName
				if exists window windowTitle then return true
			end tell
		end if
	end tell
	return false
end mainWindowExists

on openMainWindowFromMenu()
	clickMenuItem("Open Diduny")
end openMainWindowFromMenu

on openRecordingsFromMenu()
	try
		clickMenuItem("Recordings")
	on error
		if my mainWindowExists() then
			maybeClickText("Recordings")
		else
			error "Diduny menu bar item not found and main window is unavailable"
		end if
	end try
end openRecordingsFromMenu

on clickMenuItem(menuItemName)
	tell application "System Events"
		tell process appName
			set targetItem to missing value
			repeat with menuBarRef in menu bars
				try
					repeat with itemRef in menu bar items of menuBarRef
						try
							if (name of itemRef as text) is "Microphone" then
								set targetItem to itemRef
								exit repeat
							end if
						end try
					end repeat
				end try
				if targetItem is not missing value then exit repeat
			end repeat

			if targetItem is missing value then error "Diduny menu bar item not found"

			click targetItem
			delay 0.25

			if not (exists menu item menuItemName of menu 1 of targetItem) then
				error menuItemName & " menu item not found"
			end if
			click menu item menuItemName of menu 1 of targetItem
		end tell
	end tell
	delay 0.5
end clickMenuItem

on clickButton(buttonName)
	tell application "System Events"
		tell process appName
			set targetButton to my waitForButtonNamed(buttonName)
			click targetButton
		end tell
	end tell
	delay 0.15
end clickButton

on clickSheetButton(buttonName)
	tell application "System Events"
		tell process appName
			if not (exists sheet 1 of window windowTitle) then error "Sheet not found"
			set allElements to entire contents of sheet 1 of window windowTitle
			repeat with candidate in allElements
				try
					if (role of candidate as text) is "AXButton" then
						try
							if (name of candidate as text) is buttonName then
								click candidate
								return true
							end if
						end try
						try
							if (description of candidate as text) is buttonName then
								click candidate
								return true
							end if
						end try
					end if
				end try
			end repeat
		end tell
	end tell
	error "Sheet button not found: " & buttonName
end clickSheetButton

on clickText(textValue)
	tell application "System Events"
		tell process appName
			set targetText to my waitForStaticTextValue(textValue)
			click targetText
		end tell
	end tell
	delay 0.15
end clickText

on maybeClickButton(buttonName)
	tell application "System Events"
		tell process appName
			set targetButton to my firstButtonNamed(buttonName)
			if targetButton is not missing value then
				try
					if not (enabled of targetButton as boolean) then return false
				end try
				click targetButton
				delay 0.15
				return true
			end if
		end tell
	end tell
	return false
end maybeClickButton

on maybeClickText(textValue)
	tell application "System Events"
		tell process appName
			set targetText to my firstStaticTextValue(textValue)
			if targetText is not missing value then
				click targetText
				delay 0.15
				return true
			end if
		end tell
	end tell
	return false
end maybeClickText

on waitForButtonNamed(buttonName)
	repeat with i from 1 to 40
		set targetButton to firstButtonNamed(buttonName)
		if targetButton is not missing value then return targetButton
		delay 0.25
	end repeat
	error "Button not found: " & buttonName
end waitForButtonNamed

on waitForStaticTextValue(textValue)
	repeat with i from 1 to 40
		set targetText to firstStaticTextValue(textValue)
		if targetText is not missing value then return targetText
		delay 0.25
	end repeat
	error "Text not found: " & textValue
end waitForStaticTextValue

on firstButtonNamed(buttonName)
	tell application "System Events"
		tell process appName
			try
				set allElements to entire contents of window windowTitle
				repeat with candidate in allElements
					try
						if (role of candidate as text) is "AXButton" then
							try
								if (name of candidate as text) is buttonName then return candidate
							end try
							try
								if (description of candidate as text) is buttonName then return candidate
							end try
							try
								if (help of candidate as text) is buttonName then return candidate
							end try
							try
								if (value of attribute "AXIdentifier" of candidate as text) is buttonName then return candidate
							end try
						end if
					end try
				end repeat
			end try
		end tell
	end tell
	return missing value
end firstButtonNamed

on firstStaticTextValue(textValue)
	tell application "System Events"
		tell process appName
			try
				set allElements to entire contents of window windowTitle
				repeat with candidate in allElements
					try
						if (role of candidate as text) is "AXStaticText" then
							try
								if (value of candidate as text) is textValue then return candidate
							end try
							try
								if (name of candidate as text) is textValue then return candidate
							end try
						end if
					end try
				end repeat
			end try
		end tell
	end tell
	return missing value
end firstStaticTextValue

do shell script "open -a " & quoted form of appName
delay 0.5
if not mainWindowExists() then openMainWindowFromMenu()
waitForMainWindow()

tell application "System Events" to tell process appName to set frontmost to true

repeat with sectionName in {"Overview", "Recordings", "Meetings", "General", "Audio & Dictation", "Models", "Shortcuts", "Account"}
	maybeClickText(sectionName as text)
end repeat

maybeClickText("Meetings")
maybeClickButton("Skip meeting recording prompt")
if maybeClickButton("Toggle meeting selection") then
	maybeClickButton("Select Visible")
	maybeClickButton("Cancel")
end if

maybeClickText("Overview")
maybeClickButton("See all ›")
waitForStaticTextValue("Recordings")

repeat with filterName in {"All", "Meetings", "Voice notes"}
	maybeClickText(filterName as text)
end repeat

if maybeClickButton("Toggle recording selection") then
	maybeClickButton("Select Visible")
	maybeClickButton("Cancel")
end if

openRecordingsFromMenu()
waitForMainWindow()
waitForStaticTextValue("Recordings")

if maybeClickButton("Toggle recording selection") then
	maybeClickButton("Select Visible")
	maybeClickButton("Cancel")
end if

if envFlag("DIDUNY_UI_SMOKE_TRANSCRIBE") then
	clickButton("Transcribe recording")
end if

if envFlag("DIDUNY_UI_SMOKE_DELETE") then
	clickButton("Delete recording")
	delay 0.3
	clickSheetButton("Cancel")
end if

return "Diduny UI smoke completed"
