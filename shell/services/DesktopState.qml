pragma Singleton
import QtQuick
import Quickshell

// Whether the desktop icons surface holds the keyboard (set by DesktopIcons). The menu bar then shows the desktop's
// name instead of the last window's app, like Finder on macOS.
Singleton {
    property bool holdsKeyboard: false
    // The keyboard asks for the desktop (Show Desktop, GF-106): the icons surface asks the compositor for the keyboard.
    signal focusRequested
}
