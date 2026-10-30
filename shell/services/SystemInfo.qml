pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// Read-only facts about the session: the product version, whether the device is a Mac, the user. (About This Computer is
// Settings' own window since ADR-0040 step 1b: it reads the computer's facts itself.)
Singleton {
    id: root

    // The product version: the VERSION file next to the shell directory (the repository root in a dev session,
    // /usr/share/grassfield in the package); "unknown" when the file is missing. A binding on the loaded file, and the load
    // is awaited when the singleton is created, so the first reader (the startup log line) already sees the real value.
    readonly property string grassfieldVersion: versionFile.loaded ? (versionFile.text().trim() || "unknown") : "unknown"

    FileView {
        id: versionFile

        path: Quickshell.shellPath("../VERSION")
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: versionFile.waitForJob()

    // The device is a Mac (Apple hardware or an Apple keyboard, MenuShortcut.macDevice): menu shortcuts then show the macOS
    // symbols while `keyboard.shortcutStyle` is automatic. Read at start; a keyboard attached later counts from the next start.
    // Never in a visual fixture session, whose captures must not depend on the machine.
    readonly property bool macDevice: !VisualFixtures.active && MenuShortcut.macDevice(vendorFile.loaded ? vendorFile.text() : "", inputFile.loaded ? inputFile.text() : "")

    FileView {
        id: vendorFile
        path: "/sys/class/dmi/id/sys_vendor"
        printErrors: false
    }

    FileView {
        id: inputFile
        path: "/proc/bus/input/devices"
        printErrors: false
    }

    readonly property string user: VisualFixtures.active ? VisualFixtures.user : Quickshell.env("USER")
}
