pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "Minimized.js" as Minimized
import "ScreenChoice.js" as ScreenChoice
import "StagesFront.js" as StagesFront

// Compositor state and actions for the shell (master-prompt 5.2: the only place, together
// with Capabilities, that talks to the compositor). Event-driven; never polls hyprctl.
Singleton {
    id: root

    // Live toplevel list (foreign-toplevel protocol: reliable app ids, no title matching).
    readonly property var toplevels: ToplevelManager.toplevels
    readonly property var focusedToplevel: ToplevelManager.activeToplevel
    readonly property string focusedAppId: focusedToplevel ? focusedToplevel.appId : ""

    // Last Stages event (StagesFront.parse) or null; select() ignores it once it says `on:false`.
    property var stagesState: null
    // Window class the bar names while Hyprland has no active window under Stages (an Exclusive layer holds the keyboard
    // after a swap): the front app of the last Stages event while its window still exists, else "". Display only: no
    // window has the keyboard. Never set with Stages off.
    readonly property string stagesFrontAppId: {
        const live = [];
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < list.length; i++)
            live.push(list[i].address);
        return StagesFront.select(root.stagesState, !!root.focusedToplevel, Capabilities.pluginPresent, root.focusedScreenName, live);
    }

    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    // Output with keyboard/pointer focus ("" when unknown): target of keyboard-driven shell UI.
    readonly property string focusedScreenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    // Where a surface opens when nobody named an output (SUPER+N, IPC, keyboard): the active display, the first output only as
    // a last resort (ScreenChoice.js). Every such surface uses this one rule.
    readonly property string activeScreenName: ScreenChoice.pick("", focusedScreenName, Quickshell.screens.map(s => s.name))

    // A layer surface with this namespace was unmapped (`closelayer` event). The app switcher activates its target only
    // after its own exclusive surface is gone: Hyprland refuses to focus a window while one exists (FocusState.cpp).
    signal layerClosed(string namespace)

    // Something happened in the session that can take the pointer or the focus away from an interaction in progress (the Dock's
    // drag): a window opened or closed, another window, workspace or monitor became active, a monitor came or went, a layer
    // opened or closed (a surface unmapping hands the pointer back, whatever its client, shell banners included). Over-reporting is intended; `event` is the Hyprland event name.
    signal interrupted(string event)

    // A window asked for attention (Hyprland's `urgent` event, relayed here: only the platform layer reads compositor events).
    // `address` is lower-case hex without 0x. The Dock bounces the app's icon until the app is activated.
    signal attention(string address)

    // Address of a toplevel as Hyprland names it (lower-case hex without 0x), "" when Hyprland does not know it (yet).
    function addressOf(toplevel: var): string {
        const top = hyprlandToplevel(toplevel);
        return top ? Minimized.normalizeAddress(top.address) : "";
    }
    readonly property var interruptingEvents: ["openwindow", "closewindow", "movewindowv2", "activewindowv2", "workspacev2", "createworkspacev2", "destroyworkspacev2", "moveworkspacev2", "activespecialv2", "focusedmonv2", "monitoraddedv2", "monitorremovedv2", "openlayer", "closelayer", "fullscreen"]

    // Windows currently in the hidden-app workspace, as toplevel handles (see hiddenWindows).
    function isHidden(toplevel: var): bool {
        return hiddenWindows(0).some(w => w.toplevel === toplevel);
    }

    // Re-reads Hyprland's window list (pid and other IPC data are only fetched for windows that
    // existed at shell start or on this request). Call before showing data that needs the pid.
    function refreshToplevels(): void {
        Hyprland.refreshToplevels();
    }

    // Hyprland-side object of a foreign-toplevel handle (address, pid, workspace), or null.
    function hyprlandToplevel(toplevel: var): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].wayland === toplevel)
                return all[i];
        }
        return null;
    }

    // Client PID of a toplevel (from Hyprland's window data), 0 if unknown. Reactive: bindings
    // re-evaluate when refreshToplevels() delivers new data.
    function pidOf(toplevel: var): int {
        const top = hyprlandToplevel(toplevel);
        const data = top ? top.lastIpcObject : null;
        return data && data.pid ? data.pid : 0;
    }

    // Activate (focus, un-minimize) a toplevel through the protocol. A window parked by hide()
    // is first moved back to the focused workspace.
    function activate(toplevel: var): void {
        if (!toplevel)
            return;
        if (isMinimized(toplevel)) {
            unminimize(toplevel);
            return;
        }
        const top = hyprlandToplevel(toplevel);
        if (top && top.workspace && (top.workspace.name === hiddenWorkspace || top.workspace.name === minimizedWorkspace) && root.focusedWorkspace)
            dispatchRequest(moveRequest(top.address, String(root.focusedWorkspace.id)));
        toplevel.activate();
    }

    // Activate once a shell layer surface is gone. Hyprland refuses to focus a window while an Exclusive layer surface exists
    // (the switcher waits for `closelayer` for the same reason), and a popup menu that is closing still has its surface for a
    // moment: a window chosen from a menu is activated when the compositor reports `namespace` unmapped, or after
    // Tokens.dockMenuLayerWait if that event never comes. One pending request at a time (the latest wins).
    property var pendingActivation: null

    function activateAfterLayer(toplevel: var, namespace: string): void {
        if (!toplevel)
            return;
        pendingActivation = {toplevel: toplevel, namespace: namespace};
        layerWaitTimer.restart();
    }

    function runPendingActivation(): void {
        const p = pendingActivation;
        pendingActivation = null;
        layerWaitTimer.stop();
        if (p)
            activate(p.toplevel);
    }

    Timer {
        id: layerWaitTimer
        interval: Tokens.dockMenuLayerWait
        onTriggered: root.runPendingActivation()
    }

    onLayerClosed: namespace => {
        if (pendingActivation && pendingActivation.namespace === namespace)
            runPendingActivation();
    }

    // Name of the special workspace used by hide().
    readonly property string hiddenWorkspace: "special:hidden"

    // Lua request moving a window ("" when the address or workspace is invalid: the single
    // validator lives in Minimized.js, so every caller is protected).
    function moveRequest(address: string, workspace: string): string {
        return Minimized.moveRequest(address, workspace);
    }

    // Dispatches a request built by the validating builders; "" (rejected input) is dropped.
    function dispatchRequest(request: string): bool {
        if (request === "")
            return false;
        Hyprland.dispatch(request);
        return true;
    }

    // Hide (macOS "Hide"): park the window on a special workspace nobody toggles.
    function hide(toplevel: var): void {
        const top = hyprlandToplevel(toplevel);
        if (top)
            dispatchRequest(moveRequest(top.address, hiddenWorkspace));
    }

    // ---- Minimize (ADR-0002, master-prompt 5.6) ----

    // Special workspace used by the fallback minimize (no plugin).
    readonly property string minimizedWorkspace: "special:minimized"
    // Windows minimized by the shell: [{toplevel, address, appId, title}] (see Minimized.js).
    property var minimized: []
    // Per-screen Docks by screen name: each Dock instance registers itself (an object with
    // tileRect(index, adding) -> {x, y, w, h} in global layout coordinates, or null) and unregisters
    // on destruction. There is one visible Dock at a time (macOS: on the output where the pointer last reached its
    // edge): the Dock publishes that output in `dockScreenName`, and a window animates toward that Dock.
    property var dockOwners: ({})
    property string lastDockRectProblem: ""
    property string dockScreenName: ""

    function registerDock(screenName: string, owner: var): void {
        root.dockOwners[screenName] = owner;
    }

    function unregisterDock(screenName: string, owner: var): void {
        if (root.dockOwners[screenName] === owner)
            delete root.dockOwners[screenName];
    }

    // Dock tile rectangle of the minimized slot `index` (on the Dock's screen, else on `screenName`) (`adding`: a tile that does not
    // exist yet, appended before the Trash). Empty ({0,0,0,0}) without a Dock there: the plugin then
    // hides/shows the window without animation.
    // With "minimize into application icon" (dock.minimizeIntoApp) the rectangle is the tile of the window's app.
    function dockRect(screenName: string, index: int, adding: bool, toplevel: var): var {
        const owner = root.dockOwners[root.dockScreenName] || root.dockOwners[screenName];
        const rect = Minimized.finiteRect(owner ? owner.tileRect(index, adding, toplevel) : null);
        if (!rect) {
            // The plugin then hides or shows the window without animation: say why (once per reason, not per call).
            const why = !owner ? "no Dock registered for " + (root.dockScreenName || screenName) + " (registered: " + Object.keys(root.dockOwners).join(",") + ")" : "the Dock of " + (root.dockScreenName || screenName) + " has no tile rectangle for slot " + index;
            if (why !== root.lastDockRectProblem) {
                root.lastDockRectProblem = why;
                console.warn("grassfield-shell: dockRect empty: " + why);
            }
        }
        return rect || {x: 0, y: 0, w: 0, h: 0};
    }

    // Name of the monitor a window is on ("" if unknown).
    function windowScreenName(top: var): string {
        return top && top.workspace && top.workspace.monitor ? top.workspace.monitor.name : "";
    }

    // Plugin minimize/restore call (gfc/1, ADR-0007) toward/from a Dock tile. Only validated hex
    // addresses and numbers are interpolated (Minimized.windowCall).
    function pluginWindowCall(verb: string, address: string, rect: var): string {
        return Minimized.windowCall(verb, address, rect);
    }

    // Minimize a window. With the plugin ("minimize" capability) the plugin hides it with an
    // animation toward the Dock; otherwise it is parked on special:minimized. Both use the same
    // hidden state, so the shell records it either way and rebuilds the record from it.
    function minimize(toplevel: var): bool {
        if (!toplevel || Minimized.has(root.minimized, toplevel))
            return false;
        const top = hyprlandToplevel(toplevel);
        const address = top ? Minimized.normalizeAddress(top.address) : "";
        if (address === "")
            return false;
        // Rectangle of the tile this window gets (appended after the existing minimized tiles),
        // computed before the list changes.
        const tile = dockRect(windowScreenName(top) || focusedScreenName, root.minimized.length, true, toplevel);
        root.minimized = Minimized.add(root.minimized, {toplevel: toplevel, address: address, appId: toplevel.appId, title: toplevel.title, screen: windowScreenName(top)});
        if (Capabilities.has("minimize"))
            dispatchRequest(pluginWindowCall("minimize", address, tile));
        else
            dispatchRequest(moveRequest(address, minimizedWorkspace));
        return true;
    }

    // Restore a minimized window and focus it: back on the display it was minimized from, on the Desktop that display shows
    // now (owner decision D-1, macOS), never on the display of the Dock that was clicked. The plugin moves, focuses and
    // animates it itself (and gives its frame back); activating it here too would race the plugin (a focus request for a
    // window still on special:minimized opens that workspace).
    function unminimize(toplevel: var): void {
        const rec = root.minimized.find(r => r.toplevel === toplevel);
        if (!rec)
            return;
        const tile = dockRect(focusedScreenName, root.minimized.indexOf(rec), false, toplevel);
        root.minimized = Minimized.remove(root.minimized, toplevel);
        if (Capabilities.has("minimize")) {
            dispatchRequest(pluginWindowCall("restore", rec.address, tile));
            return;
        }
        const monitors = (Hyprland.monitors ? Hyprland.monitors.values : []).map(m => ({name: m.name, workspace: m.activeWorkspace ? m.activeWorkspace.id : 0}));
        const workspace = Minimized.restoreWorkspace(rec.screen || "", monitors, root.focusedWorkspace ? root.focusedWorkspace.id : 0);
        if (workspace !== "")
            dispatchRequest(moveRequest(rec.address, workspace));
        toplevel.activate();
    }

    // ---- Plugin settings (gfc/1 `config`, allowlisted keys in Minimized.js) ----

    // Settings the titlebars honor; pushed after the capabilities handshake (and again on each
    // capabilities event, e.g. a reloaded plugin) and whenever they change.
    readonly property string titlebarDoubleClick: Settings.titlebarDoubleClick
    // The minimize animation (Settings dock.minimizeEffect); Reduce Motion replaces it with a quick fade in place, as
    // macOS does. Without the plugin the fallback minimize has no animation at all.
    readonly property string minimizeEffect: Settings.reduceMotion ? "fade" : Settings.dockMinimizeEffect
    // Window tiling (macOS "Drag windows to screen edges to tile", "... to menu bar to fill screen", "Tiled windows have
    // margins"; Settings windows.tiling*): the plugin tiles titlebar drags at the edges, corners and menu bar.
    readonly property var tilingConfig: ({
            tilingEdges: Settings.windowsTilingEdges ? "true" : "false",
            tilingMenuBar: Settings.windowsTilingMenuBar ? "true" : "false",
            tilingMargins: Settings.windowsTilingMargins ? "true" : "false"
        })

    // The appearance the shell shows: the compositor-drawn titlebars follow it (feature "appearance", audit UX-06).
    readonly property string chromeAppearance: Appearance.dark ? "dark" : "light"
    // Stages (Settings windows.stages, ADR-0013, owner decision D-4): the plugin's flag follows the setting while the plugin
    // offers Stages (feature "stages-available"; "stages" is then advertised while the flag is on, and the strip sends its
    // operations with stages() below). Off by default; the flag alone changes nothing on screen until the strip sends op:on.
    // Pushed when the setting changes and when stages-available appears (a plugin load starts with the flag off), not on
    // every capabilities event: the plugin re-posts its capabilities when the flag changes, and a push there would undo a
    // flag set by the nested Stages tests (tests/compositor/stages.sh, soak.sh, minimize.sh stages).
    readonly property string stagesFlag: Settings.windowsStages ? "true" : "false"
    readonly property bool stagesAvailable: Capabilities.has("stages-available")

    function pushStagesFlag(): void {
        if (root.stagesAvailable && dispatchRequest(Minimized.configCall("stagesEnabled", root.stagesFlag)))
            console.info("grassfield: compositor setting stagesEnabled =", root.stagesFlag);
    }

    // Reduce Motion also shortens what Hyprland animates itself: window pop-in and the Spaces slide become crossfades
    // (Minimized.motionCall). Applied whenever it changes, at every shell start (the compositor keeps what the previous shell
    // set), and after a config reload while it is on (the reload restores the config's own animations, which is already
    // right when it is off).
    readonly property bool reduceMotion: Settings.reduceMotion
    onReduceMotionChanged: pushMotion()

    function pushMotion(): void {
        dispatchRequest(Minimized.motionCall(root.reduceMotion));
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "configreloaded" && root.reduceMotion)
                root.pushMotion();
        }
    }

    onTitlebarDoubleClickChanged: pushPluginConfig()
    onMinimizeEffectChanged: pushPluginConfig()
    onTilingConfigChanged: pushPluginConfig()
    onChromeAppearanceChanged: pushPluginConfig()
    onStagesFlagChanged: pushStagesFlag()
    onStagesAvailableChanged: pushStagesFlag()

    // A Stages operation (docs/specs/stages.md "Shell contract"; Minimized.stagesCall) while the plugin advertises "stages"
    // (the flag is on). False when not sent.
    function stages(request: var): bool {
        if (!Capabilities.has("stages"))
            return false;
        return dispatchRequest(Minimized.stagesCall(request));
    }

    function pushPluginConfig(): void {
        if (Capabilities.has("config") && dispatchRequest(Minimized.configCall("titlebarDoubleClick", root.titlebarDoubleClick)))
            console.info("grassfield: compositor setting titlebarDoubleClick =", root.titlebarDoubleClick);
        if (Capabilities.has("minimize-effect") && dispatchRequest(Minimized.configCall("minimizeEffect", root.minimizeEffect)))
            console.info("grassfield: compositor setting minimizeEffect =", root.minimizeEffect);
        if (Capabilities.has("appearance") && dispatchRequest(Minimized.configCall("appearance", root.chromeAppearance)))
            console.info("grassfield: compositor setting appearance =", root.chromeAppearance);
        if (Capabilities.has("window-tiling")) {
            for (const key of Object.keys(root.tilingConfig))
                dispatchRequest(Minimized.configCall(key, root.tilingConfig[key]));
        }
    }

    // Window > Move & Resize and the tiling keys (macOS 15+): the plugin places the window (FR49). False without the
    // capability or for a window Hyprland does not know.
    readonly property bool canTile: Capabilities.has("window-tiling")

    function tile(toplevel: var, place: string): bool {
        if (!root.canTile)
            return false;
        return dispatchRequest(Minimized.tileCall(addressOf(toplevel), place));
    }

    Connections {
        target: Capabilities

        function onFeaturesChanged(): void {
            root.pushPluginConfig();
        }

        function onPluginPresentChanged(): void {
            root.pushPluginConfig();
        }
    }

    // The handshake may have completed before this singleton was first used.
    Component.onCompleted: {
        pushPluginConfig();
        pushStagesFlag();
        // Always, whatever the value: Hyprland outlives the shell, so a restarted shell (or one that finds the setting off
        // after a config reset) must not leave the compositor on the reduced animations of the previous run.
        pushMotion();
    }

    function isMinimized(toplevel: var): bool {
        return Minimized.has(root.minimized, toplevel);
    }

    // Closed windows leave the minimized list.
    Connections {
        target: root.toplevels

        function onValuesChanged(): void {
            if (root.minimized.length > 0)
                root.minimized = Minimized.prune(root.minimized, root.toplevels.values);
        }
    }

    // Rebuilds the minimized list from windows sitting on special:minimized (the shell may have
    // restarted since they were minimized). Window data is re-read first, then merged. A window
    // whose latest move event took it elsewhere is skipped: re-read data can predate that move
    // (fast minimize/restore sequences re-added restored windows before this check).
    function syncMinimized(): void {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        let list = root.minimized;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            if (!top.wayland || !top.workspace || top.workspace.name !== minimizedWorkspace)
                continue;
            const address = Minimized.normalizeAddress(top.address);
            if (address === "" || (root.lastWorkspace.has(address) && root.lastWorkspace.get(address) !== minimizedWorkspace))
                continue;
            list = Minimized.add(list, {toplevel: top.wayland, address: address, appId: top.wayland.appId, title: top.wayland.title});
        }
        if (list !== root.minimized)
            root.minimized = list;
    }

    // Latest workspace name per window address, from movewindowv2 events: ordered and
    // authoritative, unlike re-read window data.
    property var lastWorkspace: new Map()

    // A window moved: onto special:minimized (by the plugin, the fallback or anything else) it is
    // recorded; off it (restored by any means) its record goes, so the Dock never shows a stale tile.
    function onWindowMoved(data: string): void {
        const move = Minimized.parseMoveWindowV2(data);
        if (!move)
            return;
        root.lastWorkspace.set(move.address, move.workspace);
        let list = root.minimized;
        if (move.workspace === minimizedWorkspace) {
            const top = (Hyprland.toplevels ? Hyprland.toplevels.values : []).find(t => Minimized.normalizeAddress(t.address) === move.address);
            if (top && top.wayland)
                list = Minimized.add(list, {toplevel: top.wayland, address: move.address, appId: top.wayland.appId, title: top.wayland.title});
            else
                minimizedSyncTimer.restart(); // handle not matched yet: merge once window data arrived
        } else {
            list = list.filter(r => r.address !== move.address);
        }
        if (list.length !== root.minimized.length)
            root.minimized = list;
    }

    // Debounced: re-read window data, then rebuild the list once it has arrived.
    Timer {
        id: minimizedSyncTimer
        interval: 100
        onTriggered: {
            Hyprland.refreshToplevels();
            minimizedMergeTimer.restart();
        }
    }

    Timer {
        id: minimizedMergeTimer
        interval: 200
        onTriggered: root.syncMinimized()
    }

    // First rebuild shortly after the shell starts (Hyprland data has to arrive first).
    Timer {
        running: true
        interval: 600
        onTriggered: minimizedSyncTimer.restart()
    }

    // The titlebar button (plugin) posts a minimize-request event; the address is validated.
    function minimizeByAddress(address: string): void {
        const wanted = Minimized.normalizeAddress(address);
        if (wanted === "")
            return;
        const top = (Hyprland.toplevels ? Hyprland.toplevels.values : []).find(t => Minimized.normalizeAddress(t.address) === wanted);
        if (top && top.wayland)
            root.minimize(top.wayland);
    }

    function hideApp(appId: string): void {
        toplevelsFor(appId).forEach(t => hide(t));
    }

    // Windows parked on special:hidden by hide(): [{address, toplevel}].
    function hiddenWindows(revision: int): var {
        const out = [];
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].workspace && all[i].workspace.name === hiddenWorkspace)
                out.push({address: all[i].address, toplevel: all[i].wayland});
        }
        return out;
    }

    // "Show All": brings every hidden window back to the focused workspace.
    function showAll(): void {
        if (!root.focusedWorkspace)
            return;
        hiddenWindows(0).forEach(w => dispatchRequest(moveRequest(Minimized.normalizeAddress(w.address), String(root.focusedWorkspace.id))));
    }

    // "Hide Others": hides every visible window of other apps.
    function hideOthers(appId: string): void {
        const keep = appId.toLowerCase();
        const all = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].appId.toLowerCase() !== keep && !isMinimized(all[i]))
                hide(all[i]);
        }
    }

    // Number of visible (not minimized, not hidden) windows of other apps.
    function othersCount(appId: string, revision: int): int {
        const keep = appId.toLowerCase();
        const hidden = hiddenWindows(revision).map(w => w.toplevel);
        const all = root.toplevels ? root.toplevels.values : [];
        return all.filter(t => t.appId.toLowerCase() !== keep && !isMinimized(t) && hidden.indexOf(t) < 0).length;
    }

    // Regular workspace id of a toplevel, 0 if unknown (special workspaces report <= 0).
    function spaceOf(toplevel: var): int {
        const top = hyprlandToplevel(toplevel);
        return top && top.workspace && top.workspace.id > 0 ? top.workspace.id : 0;
    }

    // Raise every visible window of an app, the most recent last so that it ends up focused.
    function bringAllToFront(appId: string): void {
        const list = toplevelsFor(appId).filter(t => !isMinimized(t));
        const top = mostRecent(list);
        list.filter(t => t !== top).forEach(t => activate(t));
        if (top)
            activate(top);
    }

    // Zoom = the "maximized" fullscreen mode, toggled by a dispatch (the foreign-toplevel
    // `maximized` request is ignored: windows.lua suppresses maximize events). Full screen = fullscreen
    // (ADR-0002), through the foreign-toplevel protocol.
    function toggleZoom(toplevel: var): void {
        const top = hyprlandToplevel(toplevel);
        if (top && dispatchRequest(Minimized.fullscreenRequest(top.address, "maximized")))
            requestWindowRefresh();
    }

    // Zoom state from Hyprland's window data (fullscreen mode 1), reactive on `revision`.
    function isZoomed(toplevel: var, revision: int): bool {
        const top = hyprlandToplevel(toplevel);
        return top ? Minimized.isZoomed(top.lastIpcObject) : false;
    }

    // Window data is only re-read on request. Events that change window state (fullscreen,
    // floating mode, title) request a re-read; requests inside one 50 ms window coalesce into a
    // single refresh (trailing edge, never starved by a burst), then bindings are notified once
    // the data has arrived.
    function requestWindowRefresh(): void {
        if (!windowRefreshTimer.running)
            windowRefreshTimer.start();
    }

    Timer {
        id: windowRefreshTimer
        interval: 50
        onTriggered: {
            Hyprland.refreshToplevels();
            windowNotifyTimer.restart();
        }
    }

    Timer {
        id: windowNotifyTimer
        interval: 100
        onTriggered: root.topologyRevision++
    }

    function toggleFullscreen(toplevel: var): void {
        if (toplevel)
            toplevel.fullscreen = !toplevel.fullscreen;
    }

    // Hyprland-independent entry points for key bindings (SUPER+M, SUPER+H). None acts while the session is locked
    // (GF-116: windows behind the lock are neither moved nor focused).
    IpcHandler {
        target: "windows"

        function minimize(): void {
            if (!SessionState.refuses("windows minimize"))
                root.minimize(root.focusedToplevel);
        }

        // Super+Ctrl+arrows / Super+Ctrl+R (macOS Globe+Ctrl): the focused window to a half, or back to its size.
        function tile(place: string): void {
            if (!SessionState.refuses("windows tile"))
                root.tile(root.focusedToplevel, place);
        }

        function hide(): void {
            if (root.focusedAppId !== "" && !SessionState.refuses("windows hide"))
                root.hideApp(root.focusedAppId);
        }

        // SUPER+`: next window of the focused app (macOS Cmd+`).
        function cycleApp(): void {
            if (SessionState.refuses("windows cycleApp"))
                return;
            const pool = root.toplevelsFor(root.focusedAppId).filter(t => !root.isMinimized(t));
            if (pool.length > 1)
                root.activate(root.nextAfter(pool, root.focusedToplevel));
        }
    }

    // Ask the client to close this window (xdg close request, not a kill).
    function close(toplevel: var): void {
        if (toplevel)
            toplevel.close();
    }

    // End the compositor session. In Lua mode Quickshell evaluates `hl.dispatch(<request>)`.
    function exitSession(): void {
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.exit()" : "exit");
    }

    // ---- Overview support (spec overview.md): Spaces (workspaces) and window geometry ----

    // Bumped on Hyprland events that change windows or workspaces, so that bindings calling
    // spacesOn()/windowsOn() with it as an argument re-evaluate.
    property int topologyRevision: 0
    // While true, window/workspace events trigger a debounced re-read of Hyprland's data (new
    // windows only carry geometry after a refresh). Overview sets it while open.
    property bool refreshOnEvents: false

    Timer {
        id: refreshTimer
        interval: 60
        onTriggered: root.refreshSpaces()
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield") {
                const stages = StagesFront.parse(event.data);
                if (stages) {
                    root.stagesState = stages;
                    return;
                }
                const address = Minimized.minimizeRequestAddress(event.data);
                if (address !== "")
                    root.minimizeByAddress(address);
                return;
            }
            if (event.name === "urgent") {
                const urgent = Minimized.normalizeAddress(event.data);
                if (urgent !== "")
                    root.attention(urgent);
                return;
            }
            if (root.interruptingEvents.indexOf(event.name) >= 0)
                root.interrupted(event.name);
            if (event.name === "closelayer") {
                root.layerClosed(event.data);
                return;
            }
            if (event.name === "activespecialv2") {
                // "<id>,<name>,<monitor>": the minimized parking workspace must never show as
                // an overlay (a window minimized while it is focused would keep it open).
                if (event.data.split(",")[1] === root.minimizedWorkspace)
                    Hyprland.dispatch("hl.dsp.workspace.toggle_special(\"minimized\")");
                return;
            }
            if (event.name === "windowtitlev2" || event.name === "fullscreen" || event.name === "changefloatingmode" || root.fullscreenRefreshEvents.indexOf(event.name) >= 0) {
                root.requestWindowRefresh();
                if (event.name === "windowtitlev2")
                    return;
            }
            if (event.name === "movewindowv2")
                root.onWindowMoved(event.data);
            else if (event.name === "openwindow")
                minimizedSyncTimer.restart(); // a window may map directly onto special:minimized
            else if (event.name === "closewindow")
                root.lastWorkspace.delete(Minimized.normalizeAddress(event.data));
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindowv2":
            case "workspacev2":
            case "createworkspacev2":
            case "destroyworkspacev2":
            case "moveworkspacev2":
            case "changefloatingmode":
            case "fullscreen":
                root.topologyRevision++;
                if (root.refreshOnEvents)
                    refreshTimer.restart();
            }
        }
    }

    // Re-reads windows and workspaces from Hyprland (call when Overview opens).
    function refreshSpaces(): void {
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
    }

    function monitorByName(screenName: string): var {
        const all = Hyprland.monitors ? Hyprland.monitors.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].name === screenName)
                return all[i];
        }
        return null;
    }

    // Regular workspaces (id > 0) of an output, ordered by id:
    // [{id, name, active, windowCount, appIds}].
    function spacesOn(screenName: string, revision: int): var {
        const out = [];
        const mon = monitorByName(screenName);
        const all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        const wins = windowsAcross(screenName);
        for (let i = 0; i < all.length; i++) {
            const ws = all[i];
            if (ws.id <= 0 || !ws.monitor || ws.monitor.name !== screenName)
                continue;
            const appIds = [];
            let count = 0;
            for (let j = 0; j < wins.length; j++) {
                if (wins[j].workspaceId !== ws.id)
                    continue;
                count++;
                if (appIds.indexOf(wins[j].appId) === -1)
                    appIds.push(wins[j].appId);
            }
            out.push({
                id: ws.id,
                name: ws.name,
                active: mon && mon.activeWorkspace ? mon.activeWorkspace.id === ws.id : false,
                windowCount: count,
                appIds: appIds
            });
        }
        out.sort((a, b) => a.id - b.id);
        return out;
    }

    // Mapped windows of an output on any regular workspace, monitor-relative geometry:
    // [{address, toplevel, appId, title, x, y, w, h, workspaceId, fullscreen}]. `toplevel` is the
    // foreign-toplevel handle (null until matched), usable as a capture source.
    function windowsAcross(screenName: string): var {
        const out = [];
        const mon = monitorByName(screenName);
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        if (!mon)
            return out;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            const data = top.lastIpcObject;
            if (!data || !data.at || !data.size || !data.workspace || data.workspace.id <= 0 || data.mapped === false || data.hidden === true)
                continue;
            if (data.monitor !== mon.id)
                continue;
            out.push({
                address: top.address,
                toplevel: top.wayland,
                appId: top.wayland ? top.wayland.appId : (data["class"] ? data["class"] : ""),
                title: top.title,
                x: data.at[0] - mon.x,
                y: data.at[1] - mon.y,
                w: data.size[0],
                h: data.size[1],
                workspaceId: data.workspace.id,
                fullscreen: data.fullscreen === 2
            });
        }
        return out;
    }

    // Events after which which window is full screen where may have changed (a window opened, closed or moved, another
    // workspace shown): the window data is re-read (coalesced, event-driven) so fullscreenOn stays right.
    readonly property var fullscreenRefreshEvents: ["workspacev2", "openwindow", "closewindow", "movewindowv2"]

    // True when a window of the output's shown workspace is full screen (Hyprland fullscreen mode 2, not Zoom). The menu
    // bar sits above it on the overlay layer and auto-hides. Reactive on `revision` (topologyRevision).
    function fullscreenOn(screenName: string, revision: int): bool {
        return windowsOn(screenName, revision).some(w => w.fullscreen);
    }

    // Windows on the output's currently shown workspace.
    function windowsOn(screenName: string, revision: int): var {
        const mon = monitorByName(screenName);
        const activeId = mon && mon.activeWorkspace ? mon.activeWorkspace.id : -1;
        return windowsAcross(screenName).filter(w => w.workspaceId === activeId);
    }

    // hl.plugin.grassfield.overview (feature "overview"): request {on, durationMs, curve?, windows?} in layout
    // coordinates, validated and quoted by Minimized.overviewCall. False when the request is invalid.
    function overview(request: var): bool {
        return dispatchRequest(Minimized.overviewCall(request));
    }

    // Id for a new Space: one past the highest workspace id in use.
    function nextSpaceId(): int {
        let max = 0;
        const all = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        for (let i = 0; i < all.length; i++)
            max = Math.max(max, all[i].id);
        return max + 1;
    }

    function focusSpace(id: int): void {
        if (id > 0)
            dispatchRequest(Minimized.focusRequest(Math.floor(id)));
    }

    // The window with the keyboard now, as {address, workspaceId} (null when none, or when Hyprland's data has no
    // workspace for it yet). Remembered by Overview when it opens.
    function activeWindow(): var {
        const top = hyprlandToplevel(focusedToplevel);
        if (!top || !top.workspace || top.workspace.id <= 0)
            return null;
        return {
            address: top.address,
            workspaceId: top.workspace.id
        };
    }

    // Addresses of the windows that exist now.
    function windowAddresses(): var {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        return all.map(t => t.address);
    }

    // Focuses a window by address, with its Space when that is not the one shown: the Space of the window as it is now.
    // False when the window does not exist (or has no protocol handle yet): nothing changes.
    function focusWindow(address: string): bool {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const top = all.find(t => t.address === address);
        if (!top || !top.wayland)
            return false;
        if (top.workspace && top.workspace.id > 0 && !top.workspace.active)
            focusSpace(top.workspace.id);
        // The Lua focus, not the protocol `activate`: the latter does nothing for a window Hyprland still counts as
        // focused, which is exactly the one a layer surface just took the keyboard from (measured: 11 of 12 lost).
        return dispatchRequest(Minimized.focusWindowRequest(address));
    }

    // hl.plugin.grassfield.overview_focus (feature "overview-focus"): the compositor focuses the target once the last
    // Exclusive layer is gone. False when the request is invalid (nothing is dispatched).
    function overviewFocus(target: var): bool {
        return dispatchRequest(Minimized.overviewFocusCall(target));
    }

    // Addresses of the windows the shell minimized (never given the focus).
    function minimizedAddresses(): var {
        return root.minimized.map(r => r.address);
    }

    // The window of a Desktop focused last, else its first window ("" for an empty Desktop): minimized and unmapped windows
    // never count.
    function frontWindowOn(id: int): string {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const parked = minimizedAddresses();
        let best = "";
        let bestStamp = -1;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            const data = top.lastIpcObject;
            if (!top.workspace || top.workspace.id !== id || !top.wayland || parked.indexOf(top.address) >= 0 || (data && (data.mapped === false || data.hidden === true)))
                continue;
            const stamp = recency.has(top.wayland) ? recency.get(top.wayland) : 0;
            if (stamp > bestStamp) {
                best = top.address;
                bestStamp = stamp;
            }
        }
        return best;
    }

    // Move a window to a Space without following it (the address is validated by moveRequest).
    function moveToSpace(address: string, id: int): bool {
        if (!(id > 0))
            return false;
        return dispatchRequest(moveRequest(address, String(Math.floor(id))));
    }

    // Move a window (foreign-toplevel handle) to a Space without following it.
    function moveToplevelToSpace(toplevel: var, id: int): bool {
        const top = hyprlandToplevel(toplevel);
        return top ? moveToSpace(top.address, id) : false;
    }

    // Focus recency (most recently activated wins), kept per toplevel handle.
    property var recency: new Map()

    onFocusedToplevelChanged: {
        if (focusedToplevel)
            recency.set(focusedToplevel, Date.now());
    }

    // Window to raise when an app is clicked: the most recently focused one.
    function mostRecent(list: var): var {
        let best = null;
        let bestStamp = -1;
        for (let i = 0; i < list.length; i++) {
            const stamp = recency.has(list[i]) ? recency.get(list[i]) : 0;
            if (stamp > bestStamp) {
                best = list[i];
                bestStamp = stamp;
            }
        }
        return best;
    }

    // What the Dock needs to plan a click on a running app (dock/Launch.js activationPlan): minimized, on the focused
    // Desktop (a window parked by hide() counts as here: activate() brings it back), and its focus recency.
    function windowInfo(toplevel: var): var {
        const top = hyprlandToplevel(toplevel);
        const parked = top && top.workspace && (top.workspace.name === hiddenWorkspace || top.workspace.name === minimizedWorkspace);
        const here = !top || !top.workspace || !root.focusedWorkspace || parked || top.workspace.id === root.focusedWorkspace.id;
        return {
            "ref": toplevel,
            "minimized": isMinimized(toplevel),
            "here": here,
            "stamp": recency.has(toplevel) ? recency.get(toplevel) : 0
        };
    }

    // Window after `current` in list order (wraps); the first one if current is not in the list.
    function nextAfter(list: var, current: var): var {
        if (list.length === 0)
            return null;
        const at = list.indexOf(current);
        return list[(at + 1) % list.length];
    }

    // Running toplevels belonging to an app id (case-insensitive, as desktop entry ids and
    // Wayland app ids differ in case for some toolkits).
    function toplevelsFor(appId: string): var {
        const wanted = appId.toLowerCase();
        const out = [];
        const all = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].appId.toLowerCase() === wanted)
                out.push(all[i]);
        }
        return out;
    }
}
