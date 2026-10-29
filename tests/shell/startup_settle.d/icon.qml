pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Grassfield.Ui
import qs.desktop

// tests/shell/startup_settle.sh, third scenario: an icon is invisible until it is whole, and the bounded wait
// (Tokens.desktopIconLoadTimeout) makes it visible when it never is. The launcher file is a FIFO (ICON_FIFO): its read never
// ends, so a launcher that waited for it for ever would stay invisible. Prints "startup-settle-icon: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property real early: -1
    property real started: Date.now()

    Window {
        visible: true
        width: 200
        height: 200

        DesktopIcon {
            id: icon
            name: "stuck.desktop"
            isDir: false
            filePath: Quickshell.env("ICON_FIFO")
        }
    }

    Timer {
        interval: Tokens.desktopIconLoadTimeout / 3
        running: true
        onTriggered: root.early = icon.opacity
    }

    Timer {
        interval: Tokens.desktopIconLoadTimeout + 400
        running: true
        onTriggered: {
            if (root.early !== 0)
                root.failures.push("the icon was visible (" + root.early + ") before its launcher file was read");
            if (icon.opacity !== 1)
                root.failures.push("the icon is still hidden (" + icon.opacity + ") after the load timeout");
            console.info(root.failures.length === 0 ? "startup-settle-icon: PASS" : "startup-settle-icon: FAIL " + root.failures.join("; "));
            Qt.quit();
        }
    }
}
