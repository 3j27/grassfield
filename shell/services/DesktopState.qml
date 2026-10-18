pragma Singleton
import QtQuick
import Quickshell

// Whether the desktop icons surface holds the keyboard (set by DesktopIcons). The menu bar then shows the desktop's
// name instead of the last window's app, like Finder on macOS.
Singleton {
    property bool holdsKeyboard: false
}
