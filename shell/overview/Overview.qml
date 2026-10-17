pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import qs.services

// Overview controller (spec docs/specs/overview.md, v1): owns the open state and the IPC
// target; OverviewWindow renders it, one overlay per screen.
//
// v1 draws thumbnails of the windows (ScreencopyView). When grassfield-compositor announces
// the `overview` capability (v2: real windows transformed live by the compositor), the
// thumbnails are not needed: OverviewWindow keys off `thumbnailMode`, the one branch point.
Scope {
    id: root

    property bool open: false
    // Output whose overlay holds the keyboard (focused output when opened).
    property string keyScreen: ""

    // v2 branch point: false once the compositor extension transforms the real windows.
    readonly property bool thumbnailMode: !Capabilities.has("overview")
    // Settings material.profile: full | balanced | reduced.
    readonly property string profile: Settings.materialProfile
    // Live capture for full and balanced (the capture API has no rate control, so balanced is
    // the same as full); reduced takes one snapshot per window when opening.
    readonly property bool liveCapture: profile !== "reduced"

    Binding {
        target: Compositor
        property: "refreshOnEvents"
        value: root.open
    }

    function show(): void {
        if (open)
            return;
        keyScreen = Compositor.focusedScreenName;
        Compositor.refreshSpaces();
        open = true;
    }

    function hide(): void {
        releasing = false;
        open = false;
    }

    // True between releasing the exclusive keyboard grab and the pending action.
    property bool releasing: false
    property var pending: null

    // Close Overview and focus something. While the overlay holds the keyboard exclusively the
    // compositor refocuses the previous window (and its workspace) when the overlay goes away,
    // undoing the action; so the grab is released first and the action runs shortly after.
    function closeAnd(action: var): void {
        pending = action;
        releasing = true;
        releaseTimer.restart();
    }

    Timer {
        id: releaseTimer
        interval: 80
        onTriggered: {
            const action = root.pending;
            root.pending = null;
            if (action)
                action();
            root.hide();
        }
    }

    function toggle(): void {
        if (open)
            hide();
        else
            show();
    }

    // IPC: qs ipc call overview <toggle|open|close|status>. CTRL+UP calls toggle().
    IpcHandler {
        target: "overview"

        function toggle(): void {
            root.toggle();
        }

        function open(): void {
            root.show();
        }

        function close(): void {
            root.hide();
        }

        // Test hook: JSON {open, thumbnailMode, profile, screens: [{name, windows: [{address,
        // appId, title, real, rect}], spaces, selected}]}. Rects are window-local pixels.
        function status(): string {
            const screens = [];
            const all = windows.instances;
            for (let i = 0; i < all.length; i++)
                screens.push(all[i].statusData());
            return JSON.stringify({
                open: root.open,
                thumbnailMode: root.thumbnailMode,
                profile: root.profile,
                screens: screens
            });
        }
    }

    OverviewWindow {
        id: windows
        controller: root
    }
}
