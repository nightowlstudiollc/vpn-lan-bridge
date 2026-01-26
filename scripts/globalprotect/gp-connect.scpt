-- GlobalProtect Connect Script
-- Connects to VPN if not already connected
-- Tested with GlobalProtect 6.2.x on macOS Sonoma/Sequoia
--
-- Usage:
--   osascript gp-connect.scpt

tell application "System Events" to tell process "GlobalProtect"
    click menu bar item 1 of menu bar 2
    delay 0.3

    set statusText to name of static text 1 of window 1

    if statusText is "Not Connected" then
        click button "Connect" of window 1
    end if

    delay 0.2
    click menu bar item 1 of menu bar 2
end tell
