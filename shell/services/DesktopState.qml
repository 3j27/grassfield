pragma Singleton
import QtQuick
import Quickshell
import "DesktopHolders.js" as Holders

// Whether a desktop icons surface holds the keyboard (DesktopIcons reports per display). The menu bar then shows the desktop's
// name instead of the last window's app, like Finder on macOS.
Singleton {
    id: root

    // The displays whose desktop holds the keyboard ({output name: true}).
    property var holders: ({})
    readonly property bool holdsKeyboard: Holders.any(root.holders)
    // The desktop of `key` (an output) holds the keyboard, or lets it go.
    function hold(key: string, on: bool): void {
        root.holders = Holders.updated(root.holders, key, on);
    }
    // The keyboard asks for the desktop (Show Desktop, GF-106): the icons surface asks the compositor for the keyboard.
    signal focusRequested
}
