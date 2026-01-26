-- GlobalProtect Toggle Script
-- Toggles VPN connection state (connect if disconnected, disconnect if connected)
-- Tested with GlobalProtect 6.2.x on macOS Sonoma/Sequoia
--
-- Usage:
--   osascript gp-toggle.scpt
--
-- Note: Requires Accessibility permissions for System Events

tell application "System Events" to tell process "GlobalProtect"
    -- Click the menu bar icon to open the panel
    click menu bar item 1 of menu bar 2
    delay 0.3

    -- Read current status
    set statusText to name of static text 1 of window 1

    if statusText is "Not Connected" then
        -- GlobalProtect is disconnected, so connect
        click button "Connect" of window 1
    else if statusText is "Connected" then
        -- GlobalProtect is connected, so disconnect
        -- The Disconnect button location varies by version
        set windowText to entire contents of window 1
        repeat with theItem in windowText
            if (name of theItem contains "Disconnect") then
                click theItem
                exit repeat
            end if
        end repeat
    end if

    -- Close the panel
    delay 0.2
    click menu bar item 1 of menu bar 2
end tell
