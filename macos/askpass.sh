#!/bin/bash
# The password dialog sudo shows for the installer app (SUDO_ASKPASS): installing
# Homebrew, or accepting the Xcode licence, needs the password of an administrator.
# Prints the password for sudo; Cancel prints nothing and sudo gives up.
exec osascript - "$(id -un)" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set answer to display dialog "AI Sound Design installs Homebrew, which needs administrator rights." & return & return & ¬
        "Password of this Mac's account (" & (item 1 of argv) & "):" default answer "" with hidden answer ¬
        with title "AI Sound Design Installer" with icon caution buttons {"Cancel", "OK"} default button "OK"
    return text returned of answer
end run
APPLESCRIPT
