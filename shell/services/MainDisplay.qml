pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui

// The main display (ADR-0044; macOS: Displays > "Use as" > Main display): the output that holds the Dock, the desktop icons
// and the notification banners. Chosen in Settings > Displays (`displays.main`: one remembered choice per set of connected
// displays, keyed by the displays' identity, never by connector alone); with no choice for the connected set it is the newest
// remembered choice whose display is still connected, else the built-in panel, else the first output (DisplayRole.resolve).
// It follows the outputs live: unplug the main display and the role moves to the fallback at once, plug it back and it returns.
Singleton {
    id: root

    // The connected outputs as DisplayRole.js reads them. Quickshell.screens changes when an output comes or goes.
    readonly property var displays: Quickshell.screens.map(s => ({name: s.name, model: s.model || "", serial: s.serialNumber || ""}))
    readonly property var resolved: DisplayRole.resolve(Settings.displaysMain, root.displays)
    // The name of the main output ("" with no output).
    readonly property string screenName: root.resolved.name
    // How the role was found: chosen | remembered | builtin | first | none.
    readonly property string why: root.resolved.why
    // The main display's identity key (DisplayRole.identity).
    readonly property string key: root.resolved.key
}
