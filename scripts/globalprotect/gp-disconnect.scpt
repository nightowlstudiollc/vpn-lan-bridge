-- GlobalProtect Disconnect Script
-- Disconnects VPN if currently connected
-- Tested with GlobalProtect 6.2.x on macOS Sonoma/Sequoia
--
-- Usage:
--   osascript gp-disconnect.scpt

tell application "System Events" to tell process "GlobalProtect"
    click menu bar item 1 of menu bar 2
    delay 0.3

    set statusText to name of static text 1 of window 1

    if statusText is "Connected" then
        set windowText to entire contents of window 1
        repeat with theItem in windowText
            if (name of theItem contains "Disconnect") then
                click theItem
                exit repeat
            end if
        end repeat
    end if

    delay 0.2
    click menu bar item 1 of menu bar 2
end tell
