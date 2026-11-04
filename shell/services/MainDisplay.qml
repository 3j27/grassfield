pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.lib
import qs.platform

// The main display (ADR-0044; macOS: Displays > "Use as" > Main display): the output that holds the Dock, the desktop icons
// and the notification banners. Chosen in Settings > Displays (`displays.main`: one remembered choice per set of connected
// displays, keyed by the displays' identity, never by connector alone); with no choice for the connected set it is the newest
// remembered choice whose display is still connected, else the built-in panel, else the first output (DisplayRole.resolve).
// It follows the outputs live: unplug the main display and the role moves to the fallback, plug it back and it returns.
//
// The identity (make, model, serial) is Hyprland's own `monitors` answer (platform/Displays.qml `described`): Qt's screens have
// no serial under Wayland. Until every output has been described (or `Tokens.dockSettleTimeout` has passed, a compositor
// that answers nothing) `ready` is false and `screenName` is "": the Dock waits for it, so it never latches on a fallback
// that the setting would overrule a moment later.
// Development sessions name their main output with GRASSFIELD_DESKTOP_SCREEN (a nested session has two outputs and which one
// is first is a race): it is the main display while that output exists, so it is the one source for the Dock, the desktop
// icons and the banners.
Singleton {
    id: root

    readonly property string devScreen: Mode.devValue("DESKTOP_SCREEN")
    readonly property var names: Quickshell.screens.map(s => s.name)
    // The outputs with their identity, and whether every one has been described by Hyprland.
    readonly property var live: DisplayRole.connected(root.names, Displays.described)
    // The wait for Hyprland's answer is over without it.
    property bool graceOver: false
    readonly property bool ready: root.names.length > 0 && (root.devScreen !== "" || root.live.ready || root.graceOver)

    // The outputs the choice is resolved against: they follow `live` once it has settled (a hot-plug is a burst of changes,
    // Tokens.motionSlow), at once the first time.
    property var displays: []
    // `displays` holds a described snapshot (the first one is taken at once, the later ones after the burst).
    property bool described: false
    readonly property var resolved: root.ready ? DisplayRole.resolve(Settings.displaysMain, root.displays) : ({name: "", key: "", why: "none"})
    // The name of the main output ("" while not ready or with no output).
    readonly property string screenName: root.devScreen !== "" && root.names.indexOf(root.devScreen) >= 0 ? root.devScreen : root.resolved.name
    // How the role was found: chosen | remembered | builtin | first | none.
    readonly property string why: root.resolved.why
    // The main display's identity key (DisplayRole.identity).
    readonly property string key: root.resolved.key

    function apply(): void {
        root.displays = root.live.displays;
        root.described = root.live.ready;
    }

    onLiveChanged: {
        if (!root.described)
            root.apply();
        else
            settle.restart();
    }

    Component.onCompleted: root.apply()

    Timer {
        id: settle
        interval: Tokens.motionSlow
        onTriggered: root.apply()
    }

    Timer {
        interval: Tokens.dockSettleTimeout
        running: !root.graceOver
        onTriggered: root.graceOver = true
    }
}
