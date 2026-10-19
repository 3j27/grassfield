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

    // Single lifecycle value (V2.keyboardPlan / V2.keysEnabled): "closed" | "open" | "releasing". `open` and
    // `releasing` derive from it, so no state between releasing and closed can read as open.
    property string stage: "closed"
    readonly property bool open: stage !== "closed"
    // The window that had the keyboard when the overview opened ({address, workspaceId}, null for none, or when the
    // desktop had it): a close without a chosen window returns to it (macOS: leaving Mission Control without choosing
    // brings back the window and the Desktop you were on).
    property var previous: null
    // A Desktop created with "+" while open (the shell switched to it): closing without a choice stays there.
    property int stayOnSpace: 0

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

    // The session lock owns the screen and the keyboard (set from shell.qml): nothing is focused by the shell, and an
    // open overview closes without a request.
    property bool locked: false
    onLockedChanged: {
        if (locked)
            requestCloseForOther();
    }

    // Selection, one for all outputs (OverviewWindow reads it): a window address ("" none) and, with the keyboard in the
    // Spaces bar of the output `spaceScreen`, the tile index (-1 while the windows have it).
    property string selected: ""
    property int spaceFocus: -1
    property string spaceScreen: ""

    function show(): void {
        if (open)
            return;
        focusTimer.stop();
        focusPlan = null;
        previous = DesktopState.holdsKeyboard ? null : Compositor.activeWindow();
        selected = "";
        spaceFocus = -1;
        spaceScreen = "";
        stayOnSpace = 0;
        Compositor.refreshSpaces();
        phase = "idle";
        live = false;
        retries = 0;
        switchingSpace = false;
        // A full-screen window on a shown Space cannot be transformed (and stops the others of its Space being
        // transformed): thumbnails for this open.
        thumbsThisOpen = !Capabilities.has("overview") || fullscreenShown();
        stage = "open";
        if (!thumbsThisOpen)
            chromeWait.restart();
    }

    function hide(): void {
        closeV2();
        chromeWait.stop();
        retryTimer.stop();
        releaseTimer.stop();
        releaseBound.stop();
        keepScreen = "";
        pending = null;
        stage = "closed";
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
        // The keyboard moved between chromes while releasing: wait again for the ones still to commit.
        if (releasing) {
            releaseSettled = false;
            releaseTimer.restart();
        }
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
            // The plugin ended the overview itself (a Desktop switch, the lock): the same close as every other, so the
            // chromes release their keyboard in order and the focus request goes out (target none: the plugin's own
            // fallback, the front window of the Desktop shown). When the release is already running (the keyboard
            // leaving the chrome ends the plugin's overview too) that close is simply carried on.
            if (stage === "open")
                closeAnd({
                    kind: "none"
                });
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
    readonly property bool releasing: stage === "releasing"
    // Output whose chrome is kept Exclusive during the first part of the release (the holder, released last).
    property string keepScreen: ""
    // Keyboard mode of every output's chrome (V2.keyboardPlan): all Exclusive while open; releasing: all None but the
    // holder, then all None.
    readonly property var keyboardPlan: V2.keyboardPlan(Quickshell.screens.map(s => s.name), stage, keepScreen)
    // The focus target of the close in progress (V2.closeTarget) and whether the plugin was given it.
    property var pending: null
    property bool focusViaPlugin: false

    // Close Overview, then focus something (docs/specs/overview.md "Close focus"). `choice` is what the user did (see
    // V2.closeTarget): a window, a Desktop, nothing (null: Esc, toggle, backdrop), or "none" / "other" (the plugin ended
    // the overview; another surface takes the keyboard). The target is worked out once, at the start:
    //  - with the plugin capability `overview-focus` ONE request goes out now, before the chromes drop to None; the
    //    compositor waits for the last Exclusive layer and focuses (no shell focus action, no race with the layers);
    //  - without it the shell focuses after the chromes are released and checks the result (retryFocus).
    // Each output's chrome commits its keyboard mode on its own, so the order is: every chrome but the holder drops to
    // None; after the settle pause the holder drops too; the close waits until no chrome reports the keyboard and the
    // settle pause has passed again (V2.releaseDone, bounded by releaseBound); then on:false is sent and the chromes hide.
    property bool releaseSettled: false

    function closeAnd(choice: var): void {
        if (stage !== "open")
            return;
        const target = V2.closeTarget(choice, previous, stayOnSpace);
        focusViaPlugin = target.kind !== "skip" && !locked && Capabilities.has("overview-focus") && Compositor.overviewFocus(target);
        pending = target;
        releaseSettled = false;
        keepScreen = holderScreen();
        stage = "releasing";
        releaseTimer.restart();
        releaseBound.restart();
    }

    // Output of the chrome that holds the keyboard ("" for none).
    function holderScreen(): string {
        return Object.keys(chromeActive).find(k => chromeActive[k]) || "";
    }

    function tryFinishRelease(forced: bool): void {
        if (releasing && V2.releaseDone(chromeHeld, releaseSettled, forced))
            finishRelease();
    }

    function finishRelease(): void {
        releaseTimer.stop();
        releaseBound.stop();
        keepScreen = "";
        const target = pending;
        const viaPlugin = focusViaPlugin;
        try {
            closeV2();
        } finally {
            hide();
        }
        if (!viaPlugin && !locked)
            startFocus(target);
    }

    // ---- Without the plugin capability: focus, check, retry ----

    // {kind: "window", address} | {kind: "space", id} (V2.fallbackPlan), the goal of the current attempt, the attempt
    // number and when the first one started.
    property var focusPlan: null
    property var focusGoal: null
    property int focusAttempt: 0
    property real focusStarted: 0

    function startFocus(target: var): void {
        const plan = V2.fallbackPlan(target, Compositor.windowAddresses(), Compositor.minimizedAddresses(), Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : 0);
        if (plan.kind === "none")
            return;
        focusPlan = plan;
        focusAttempt = 0;
        focusStarted = Date.now();
        attemptFocus();
    }

    // The Lua focus dispatch (Compositor.focusWindow: the protocol `activate` does nothing for the window Hyprland still
    // counts as focused). For a Desktop the window focused last on it, else the Desktop itself.
    function attemptFocus(): void {
        const plan = focusPlan;
        if (!plan || locked) {
            focusPlan = null;
            return;
        }
        let address = plan.address;
        if (plan.kind === "space")
            address = Compositor.frontWindowOn(plan.id);
        if (address) {
            focusGoal = {
                address: address
            };
            Compositor.focusWindow(address);
        } else {
            focusGoal = {
                workspace: plan.id
            };
            Compositor.focusSpace(plan.id);
        }
        focusTimer.interval = V2.retryDelay(focusAttempt, Tokens.overviewFocusRetryMs);
        focusTimer.restart();
    }

    // Whether the focus holds (activewindow through the foreign-toplevel state, the focused workspace): done, else try
    // again with a longer wait until the bound runs out (Hyprland's own choice then stands).
    Timer {
        id: focusTimer
        onTriggered: {
            const ws = Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : -1;
            if (V2.focusHolds(root.focusGoal, Compositor.activeWindow(), ws) || Date.now() - root.focusStarted >= Tokens.overviewFocusBoundMs || root.open) {
                root.focusPlan = null;
                return;
            }
            root.focusAttempt++;
            root.attemptFocus();
        }
    }

    // ---- Selection (one for all outputs) ----

    function windowOf(address: string): var {
        return windows.instances.find(w => w.winKeys.indexOf(address) >= 0) ?? null;
    }

    function hoverSelect(address: string): void {
        spaceFocus = -1;
        selected = address;
    }

    // Arrow keys. Nothing selected: the window that was active at open (macOS), wherever it is. Otherwise the neighbour
    // on that output, else the window entered on the output lying that way; up with nothing above enters the Desktops bar.
    function arrow(dir: string): void {
        const all = windows.instances;
        if (spaceFocus >= 0) {
            const owner = all.find(w => w.screenName === spaceScreen);
            if (dir === "down") {
                spaceFocus = -1;
            } else if ((dir === "left" || dir === "right") && owner) {
                spaceFocus = Math.max(0, Math.min(spaceFocus + (dir === "left" ? -1 : 1), owner.tiles.length - 1));
            }
            return;
        }
        const owner = windowOf(selected);
        if (!owner) {
            selected = V2.startSelection(previous, all.map(w => ({
                        name: w.screenName,
                        addresses: w.winKeys
                    })));
            return;
        }
        const next = owner.neighborOf(selected, dir);
        if (next !== "") {
            selected = next;
            return;
        }
        if (dir === "up") {
            if (owner.tiles.length > 0) {
                spaceScreen = owner.screenName;
                spaceFocus = owner.activeTileIndex();
            }
            return;
        }
        const toName = V2.adjacentScreen(all.map(w => ({
                    name: w.screenName,
                    x: w.modelData.x,
                    y: w.modelData.y,
                    w: w.modelData.width,
                    h: w.modelData.height
                })), owner.screenName, dir);
        const dest = toName === "" ? null : all.find(w => w.screenName === toName);
        const entry = dest ? dest.entryFor(dir, owner.crossFraction(selected, dir)) : "";
        if (entry !== "")
            selected = entry;
    }

    // Tab order: windows (-1), then each Desktop tile of the output holding the selection, then back to the windows.
    function cycle(step: int): void {
        const owner = spaceFocus >= 0 ? windows.instances.find(w => w.screenName === spaceScreen) : (windowOf(selected) ?? windows.instances[0]);
        if (!owner)
            return;
        let next = spaceFocus + step;
        if (next >= owner.tiles.length || next < -1)
            next = step > 0 ? -1 : owner.tiles.length - 1;
        spaceScreen = owner.screenName;
        spaceFocus = next;
    }

    function activateSelection(): void {
        if (spaceFocus >= 0) {
            const owner = windows.instances.find(w => w.screenName === spaceScreen);
            if (owner)
                owner.activateTile(spaceFocus);
        } else if (selected !== "") {
            const owner = windowOf(selected);
            if (owner)
                owner.activateWindow(selected);
        }
    }

    Timer {
        id: releaseTimer
        interval: Tokens.overviewReleaseSettleMs
        onTriggered: {
            if (root.keepScreen !== "") {
                // The other chromes have committed: release the holder, then wait for it.
                root.keepScreen = "";
                root.releaseSettled = false;
                releaseTimer.restart();
                return;
            }
            root.releaseSettled = true;
            root.tryFinishRelease(false);
        }
    }

    Timer {
        id: releaseBound
        interval: Tokens.overviewReleaseBoundMs
        onTriggered: root.tryFinishRelease(true)
    }

    // Close because another full-attention surface opened (ExclusiveSurfaces): the keyboard belongs to that surface, so
    // nothing is focused here.
    function requestCloseForOther(): void {
        if (stage === "open")
            closeAnd({
                kind: "other"
            });
    }

    // Close from outside (IPC, shortcut): same path as Esc, the keyboard is released before the close completes.
    function requestClose(): void {
        if (stage === "open")
            closeAnd(null);
    }

    function toggle(): void {
        if (open)
            requestClose();
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
            root.requestClose();
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
