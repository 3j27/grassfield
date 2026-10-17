pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Minimized.js" as Minimized

// Compositor state and actions for the shell (master-prompt 5.2: the only place, together
// with Capabilities, that talks to the compositor). Event-driven; never polls hyprctl.
Singleton {
    id: root

    // Live toplevel list (foreign-toplevel protocol: reliable app ids, no title matching).
    readonly property var toplevels: ToplevelManager.toplevels
    readonly property var focusedToplevel: ToplevelManager.activeToplevel
    readonly property string focusedAppId: focusedToplevel ? focusedToplevel.appId : ""

    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    // Output with keyboard/pointer focus ("" when unknown): target of keyboard-driven shell UI.
    readonly property string focusedScreenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

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
        const top = hyprlandToplevel(toplevel);
        if (top && top.workspace && (top.workspace.name === hiddenWorkspace || top.workspace.name === minimizedWorkspace) && root.focusedWorkspace)
            dispatchRequest(moveRequest(top.address, String(root.focusedWorkspace.id)));
        if (isMinimized(toplevel))
            unminimize(toplevel);
        else
            toplevel.activate();
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
    // Dock icon rectangle in screen coordinates {x, y, w, h}, published by the Dock; the plugin
    // animates toward it. null until a Dock exists.
    property var dockTarget: null

    // Plugin verb call (ADR-0007), wrapped as a Lua function like the hello request. Only
    // validated hex addresses and numbers are interpolated.
    function pluginRequest(verb: string, address: string, rect: var): string {
        const hex = Minimized.normalizeAddress(address);
        if (hex === "" || (rect && !Minimized.finiteRect(rect)))
            return "";
        const args = ["\"0x" + hex + "\""];
        if (rect)
            [rect.x, rect.y, rect.w, rect.h].forEach(n => args.push(String(Math.round(Number(n)))));
        return "function() local p = hl.plugin and hl.plugin.grassfield; if p and p." + verb + " then p." + verb + "(" + args.join(", ") + ") end end";
    }

    // Minimize a window. With the plugin ("minimize" capability) the plugin hides it with an
    // animation toward the Dock; otherwise it is parked on special:minimized. Either way the
    // shell records it so the Dock can list and restore it.
    function minimize(toplevel: var): bool {
        if (!toplevel || Minimized.has(root.minimized, toplevel))
            return false;
        const top = hyprlandToplevel(toplevel);
        const address = top ? Minimized.normalizeAddress(top.address) : "";
        if (address === "")
            return false;
        root.minimized = Minimized.add(root.minimized, {toplevel: toplevel, address: address, appId: toplevel.appId, title: toplevel.title});
        if (Capabilities.has("minimize"))
            dispatchRequest(pluginRequest("minimize", address, Minimized.finiteRect(root.dockTarget) || {x: 0, y: 0, w: 0, h: 0}));
        else
            dispatchRequest(moveRequest(address, minimizedWorkspace));
        return true;
    }

    // Restore a minimized window to the current workspace and focus it.
    function unminimize(toplevel: var): void {
        const rec = root.minimized.find(r => r.toplevel === toplevel);
        if (!rec)
            return;
        root.minimized = Minimized.remove(root.minimized, toplevel);
        if (Capabilities.has("minimize"))
            dispatchRequest(pluginRequest("restore", rec.address, null));
        else if (root.focusedWorkspace)
            dispatchRequest(moveRequest(rec.address, String(root.focusedWorkspace.id)));
        toplevel.activate();
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
    // restarted since they were minimized). Window data is re-read first, then merged.
    function syncMinimized(): void {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        let list = root.minimized;
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            if (!top.wayland || !top.workspace || top.workspace.name !== minimizedWorkspace)
                continue;
            const address = Minimized.normalizeAddress(top.address);
            if (address !== "")
                list = Minimized.add(list, {toplevel: top.wayland, address: address, appId: top.wayland.appId, title: top.wayland.title});
        }
        if (list !== root.minimized)
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

    // Hyprland-independent entry points for key bindings (SUPER+M, SUPER+H).
    IpcHandler {
        target: "windows"

        function minimize(): void {
            root.minimize(root.focusedToplevel);
        }

        function hide(): void {
            if (root.focusedAppId !== "")
                root.hideApp(root.focusedAppId);
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
                const address = Minimized.minimizeRequestAddress(event.data);
                if (address !== "")
                    root.minimizeByAddress(address);
                return;
            }
            if (event.name === "activespecialv2") {
                // "<id>,<name>,<monitor>": the minimized parking workspace must never show as
                // an overlay (a window minimized while it is focused would keep it open).
                if (event.data.split(",")[1] === root.minimizedWorkspace)
                    Hyprland.dispatch("hl.dsp.workspace.toggle_special(\"minimized\")");
                return;
            }
            if (event.name === "windowtitlev2" || event.name === "fullscreen" || event.name === "changefloatingmode") {
                root.requestWindowRefresh();
                if (event.name === "windowtitlev2")
                    return;
            }
            if ((event.name === "openwindow" || event.name === "movewindowv2") && (event.name === "openwindow" || event.data.indexOf(root.minimizedWorkspace) >= 0))
                minimizedSyncTimer.restart();
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
    // [{address, toplevel, appId, title, x, y, w, h, workspaceId}]. `toplevel` is the
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
                workspaceId: data.workspace.id
            });
        }
        return out;
    }

    // Windows on the output's currently shown workspace.
    function windowsOn(screenName: string, revision: int): var {
        const mon = monitorByName(screenName);
        const activeId = mon && mon.activeWorkspace ? mon.activeWorkspace.id : -1;
        return windowsAcross(screenName).filter(w => w.workspaceId === activeId);
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
