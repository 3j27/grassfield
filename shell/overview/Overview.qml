pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Grassfield.Ui
import qs.platform
import qs.services
import "V2.js" as V2

// Overview controller (spec docs/specs/overview.md): owns the open state, the IPC target and, with the compositor
// capability `overview` (v2), the conversation with grassfield-compositor; OverviewWindow renders it (one chrome
// overlay per screen) and OverviewBackdrop dims the desktop (Bottom layer, v2 only).
//
// v1 draws thumbnails of the windows (ScreencopyView). v2 lets the compositor transform the real windows live
// (Shell contract in the spec): the chrome is mapped and holds the keyboard (Exclusive) first, then the layout is sent
// with `overview(json)`; the plugin's events say what happened. Refused request, plugin loss, a full-screen window or
// no capability: thumbnails for that open (`thumbnailMode`, the one branch point).
Scope {
    id: root

    property bool open: false
    // Output whose overlay holds the keyboard (focused output when opened).
    property string keyScreen: ""

    // v2 branch point: false while the compositor transforms the real windows. Thumbnails when the plugin has no
    // `overview` feature (now or at the time of this open), or when this open fell back (refusal, full-screen window,
    // chrome not holding the keyboard in time).
    property bool thumbsThisOpen: !Capabilities.has("overview")
    readonly property bool thumbnailMode: thumbsThisOpen || !Capabilities.has("overview")
    // Plugin side state seen through its events: idle | opening | open | closing.
    property string phase: "idle"
    // The layout was sent (on:true) and no close was sent since: the windows may be transformed.
    property bool live: false
    // A chrome surface holds the keyboard (reported by OverviewWindow); the plugin refuses on:true without it.
    property var chromeActive: ({})
    readonly property bool chromeHeld: Object.keys(chromeActive).some(k => chromeActive[k])
    // The shell itself switched Space while open ("+"): the plugin ends the overview then, the chrome stays.
    property bool switchingSpace: false
    property int retries: 0
    readonly property int durationMs: Appearance.reduceMotion ? 0 : Tokens.motionSlow
    // Settings material.profile: full | balanced | reduced.
    readonly property string profile: Settings.materialProfile
    // full: live capture. balanced: ScreencopyView has no rate control, so single frames are
    // requested every overviewBalancedIntervalMs. reduced: one snapshot per window when opening.

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
        phase = "idle";
        live = false;
        retries = 0;
        switchingSpace = false;
        // A full-screen window on a shown Space cannot be transformed (and stops the others of its Space being
        // transformed): thumbnails for this open.
        thumbsThisOpen = !Capabilities.has("overview") || fullscreenShown();
        open = true;
        if (!thumbsThisOpen)
            chromeWait.restart();
    }

    function hide(): void {
        closeV2();
        chromeWait.stop();
        retryTimer.stop();
        releasing = false;
        open = false;
    }

    function fullscreenShown(): bool {
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const list = Compositor.windowsOn(Quickshell.screens[i].name, Compositor.topologyRevision);
            if (list.some(w => w.fullscreen))
                return true;
        }
        return false;
    }

    // ---- v2: the conversation with grassfield-compositor ----

    function curve(): var {
        return Tokens.motionCurveStandard.slice(0, 4);
    }

    // Layout rectangles (layout coordinates) of every output's windows, from the shell's own layout.
    function layoutWindows(): var {
        const out = [];
        const all = windows.instances;
        for (let i = 0; i < all.length; i++)
            all[i].v2Rects().forEach(r => out.push(r));
        return out;
    }

    // Sends the layout (open, or retarget while open). Only once a chrome holds the keyboard.
    function sendLayout(): void {
        if (!open || thumbnailMode || releasing || !chromeHeld || closing)
            return;
        const list = layoutWindows();
        if (list.length === 0)
            return;
        live = Compositor.overview({
            on: true,
            durationMs: durationMs,
            curve: curve(),
            windows: list
        });
        chromeWait.stop();
    }

    // The layout changed while open (window opened, closed, moved to a Space): the plugin continues from where each
    // window is drawn.
    function layoutChanged(): void {
        if (open && live)
            Qt.callLater(sendLayout);
    }

    property bool closing: false

    // on:false: the plugin animates back; the chrome may unmap right after.
    function closeV2(): void {
        if (closing || !live)
            return;
        closing = true;
        Compositor.overview({
            on: false,
            durationMs: durationMs,
            curve: curve()
        });
        live = false;
    }

    function fallbackToThumbnails(): void {
        chromeWait.stop();
        if (live) {
            // Windows may be transformed: put them back at once, then thumbnails.
            Compositor.overview({
                on: false,
                durationMs: 0
            });
            live = false;
        }
        thumbsThisOpen = true;
    }

    function onChromeChanged(screenName: string, active: bool): void {
        const next = Object.assign({}, chromeActive);
        next[screenName] = active;
        chromeActive = next;
    }

    onChromeHeldChanged: {
        if (chromeHeld && open && !thumbnailMode && !live)
            sendLayout();
    }
    onOpenChanged: {
        if (open)
            closing = false;
    }

    // The chrome did not get the keyboard in time: the plugin would refuse, show thumbnails.
    Timer {
        id: chromeWait
        interval: Tokens.overviewChromeWaitMs
        onTriggered: {
            if (root.open && !root.live && !root.thumbnailMode)
                root.fallbackToThumbnails();
        }
    }

    // One retry of a request refused with no-chrome (another output's Exclusive commit may lag).
    Timer {
        id: retryTimer
        interval: Tokens.overviewChromeRetryMs
        onTriggered: root.sendLayout()
    }

    function onPluginEvent(event: var): void {
        const d = V2.decide(phase, open, event);
        phase = d.phase;
        if (d.retry) {
            if (retries < 1) {
                retries++;
                live = false;
                retryTimer.restart();
            } else {
                fallbackToThumbnails();
            }
        }
        if (d.fallback)
            fallbackToThumbnails();
        // Ended without the shell's on:false. After "+" the shell switched Space itself: the chrome stays.
        if (d.close && !switchingSpace) {
            live = false;
            closing = true;
            hide();
        } else if (d.close) {
            live = false;
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name !== "grassfield")
                return;
            const parsed = V2.parseEvent(event.data);
            if (parsed)
                root.onPluginEvent(parsed);
        }
    }

    // Restart (Shell contract 7): after every capabilities event, with no overview open, make sure the plugin has none
    // either (idempotent: a closed overview answers `closed`).
    Connections {
        target: Capabilities

        function onFeaturesChanged(): void {
            if (!root.open && Capabilities.has("overview"))
                Compositor.overview({
                    on: false,
                    durationMs: 0
                });
        }
    }

    // True between releasing the exclusive keyboard grab and the pending action.
    property bool releasing: false
    property var pending: null

    // Close Overview and focus something. While the overlay holds the keyboard exclusively the
    // compositor refocuses the previous window (and its workspace) when the overlay goes away,
    // undoing the action; so the grab is released first and the action runs shortly after.
    function closeAnd(action: var): void {
        // v2: ask for the closing animation first; releasing the grab below would otherwise end it at once.
        closeV2();
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
            try {
                if (action)
                    action();
            } finally {
                root.hide();
            }
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
                phase: root.phase,
                live: root.live,
                chromeHeld: root.chromeHeld,
                profile: root.profile,
                screens: screens
            });
        }
    }

    OverviewBackdrop {
        controller: root
    }

    OverviewWindow {
        id: windows
        controller: root
    }
}
