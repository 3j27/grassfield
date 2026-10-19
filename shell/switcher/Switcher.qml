pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../dock/DockModel.js" as DockModel
import "SwitcherModel.js" as Model

// App switcher controller (spec docs/specs/switcher.md; macOS Cmd+Tab): owns the session (Model.reduce), the app list and
// the IPC target `switcher`. SwitcherWindow renders it on the focused output.
//
// The compositor side (config/hypr/grassfield/bindings.lua) enters the key map "switcher" on SUPER+TAB, binds Tab, arrows,
// Q, H and Esc inside it, and leaves it, with a `release` request, when SUPER is released.
Scope {
    id: root

    // Session reducer state (SwitcherModel.js): phase idle | pending | shown.
    property var session: Model.idle()
    readonly property string phase: session.phase
    readonly property bool shown: session.phase === "shown"
    readonly property int selected: session.selected
    // Apps in frozen MRU order for this session: {key, name, icon, entry, windows, stamp}.
    property var apps: []
    property string screenName: ""
    // The compositor left the key map (modifier released) at this time; 0 while held or never seen.
    property real releasedAt: 0
    property bool heldSeen: false
    // App chosen by a commit, activated once the panel is gone.
    property var target: null

    // Surfaces of the shell itself are layer surfaces, never toplevels; this only guards against a window of the shell.
    readonly property var excluded: ["grassfield-shell", "quickshell"]

    function windowsNow(): var {
        const out = [];
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let i = 0; i < tops.length; i++)
            out.push({appId: tops[i].appId, ref: tops[i]});
        return out;
    }

    function freshApps(): var {
        Apps.revision;
        return Model.apps(DockModel.merge, windowsNow(), Apps.lookup, t => Compositor.recency.has(t) ? Compositor.recency.get(t) : 0, excluded);
    }

    function apply(result: var): void {
        const before = session.phase;
        session = result.state;
        switch (result.action) {
        case "show":
            openPanel();
            break;
        case "commit":
            showTimer.stop();
            backstop.stop();
            commit(result.index, before === "shown");
            break;
        case "cancel":
            showTimer.stop();
            backstop.stop();
            break;
        }
    }

    function openPanel(): void {
        Popups.close();
        showTimer.stop();
        screenName = Compositor.focusedScreenName;
        if (screenName === "" && Quickshell.screens.length > 0)
            screenName = Quickshell.screens[0].name;
    }

    // dir: +1 (Tab, Right) or -1 (Shift+Tab, Left). Arrows only move an open session.
    function step(dir: int, arrow: bool): void {
        if (arrow && session.phase === "idle")
            return;
        const starting = session.phase === "idle";
        if (starting)
            apps = freshApps();
        apply(Model.reduce(session, {type: "step", dir: dir, count: apps.length}));
        if (!starting || session.phase !== "pending")
            return;
        // A quick press: the key map was already left when this request arrived, so the modifier is up.
        if (Compositor.submap !== "switcher" && releasedAt > 0 && Date.now() - releasedAt < Tokens.switcherBackstopMs * 2) {
            releasedAt = 0;
            release();
            return;
        }
        showTimer.restart();
    }

    function release(): void {
        apply(Model.reduce(session, {type: "release"}));
    }

    function cancel(): void {
        apply(Model.reduce(session, {type: "cancel"}));
    }

    function hover(index: int): void {
        apply(Model.reduce(session, {type: "hover", index: index}));
    }

    function click(index: int): void {
        apply(Model.reduce(session, {type: "click", index: index}));
    }

    // Q while open: ask every window of the selected app to close (the Dock's Quit path; never a kill).
    function quitSelected(): void {
        const app = apps[selected];
        if (!shown || !app)
            return;
        app.windows.forEach(t => Compositor.close(t));
    }

    // H while open: hide the selected app.
    function hideSelected(): void {
        const app = apps[selected];
        if (!shown || !app)
            return;
        app.windows.forEach(t => Compositor.hide(t));
    }

    // Raises the app's most recent window (un-minimizes when all are minimized; its Space and Stage come forward through
    // the compositor's focus path). With the panel up, the activation waits for the panel to unmap first.
    function commit(index: int, wasShown: bool): void {
        const app = apps[index];
        if (!app)
            return;
        target = app;
        if (wasShown)
            commitTimer.restart();
        else
            activateTarget();
    }

    function activateTarget(): void {
        const app = target;
        target = null;
        if (!app)
            return;
        const live = app.windows.filter(t => !Compositor.isMinimized(t));
        const pool = live.length > 0 ? live : app.windows;
        Compositor.activate(Compositor.mostRecent(pool) || pool[0]);
    }

    Timer {
        id: showTimer
        interval: Tokens.switcherShowDelayMs
        onTriggered: root.apply(Model.reduce(root.session, {type: "timer"}))
    }

    Timer {
        id: commitTimer
        interval: Tokens.switcherCommitDelayMs
        onTriggered: root.activateTarget()
    }

    // The key map was left but the release request never arrived: commit on our own.
    Timer {
        id: backstop
        interval: Tokens.switcherBackstopMs
        onTriggered: root.release()
    }

    Connections {
        target: Compositor

        function onSubmapChanged(): void {
            if (Compositor.submap === "switcher") {
                root.heldSeen = true;
                root.releasedAt = 0;
            } else if (root.heldSeen) {
                root.heldSeen = false;
                root.releasedAt = Date.now();
                if (root.phase !== "idle")
                    backstop.restart();
            }
        }
    }

    // Apps quit or closed while the session is open.
    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            if (root.phase === "idle")
                return;
            const current = root.apps[root.selected];
            const next = Model.refresh(root.apps, root.freshApps());
            root.apps = next;
            const index = current ? next.findIndex(a => a.key === current.key) : -1;
            root.apply(Model.reduce(root.session, {type: "count", count: next.length, selected: index}));
        }
    }

    IpcHandler {
        target: "switcher"

        function next(): void {
            root.step(1, false);
        }

        function previous(): void {
            root.step(-1, false);
        }

        function right(): void {
            root.step(1, true);
        }

        function left(): void {
            root.step(-1, true);
        }

        function release(): void {
            root.release();
        }

        function cancel(): void {
            root.cancel();
        }

        function quit(): void {
            root.quitSelected();
        }

        function hide(): void {
            root.hideSelected();
        }

        function status(): string {
            return JSON.stringify({phase: root.phase, selected: root.selected, apps: root.apps.map(a => a.key), submap: Compositor.submap});
        }
    }
}
