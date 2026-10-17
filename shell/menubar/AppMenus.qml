pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import qs.services
import "model"

// Live context and actions of the application menus (app, File, Window). Models come from
// AppMenuModel (pure); every item runs a real action through the platform layer.
Singleton {
    id: root

    readonly property AppMenuModel model: AppMenuModel {}

    // Desktop entry id -> SingleMainWindow=true. Quickshell does not expose that key, so one
    // small shell loop reads it from the entry file (absent key = false).
    property var singleMain: ({})
    property string pending: ""

    function probe(entryId: string): void {
        if (entryId === "" || root.singleMain[entryId] !== undefined)
            return;
        if (prober.running) {
            root.pending = entryId;
            return;
        }
        prober.entryId = entryId;
        prober.running = true;
    }

    Process {
        id: prober

        property string entryId: ""

        // The id is passed as an argument, never interpolated into the script.
        command: ["sh", "-c", "for d in \"${XDG_DATA_HOME:-$HOME/.local/share}\" $(echo \"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\" | tr : ' '); do f=\"$d/applications/$1.desktop\"; if [ -f \"$f\" ]; then if grep -qix 'SingleMainWindow=true' \"$f\"; then echo true; else echo false; fi; exit; fi; done; echo false", "sh", entryId]
        stdout: StdioCollector {
            onStreamFinished: {
                const next = Object.assign({}, root.singleMain);
                next[prober.entryId] = text.trim() === "true";
                root.singleMain = next;
                const wait = root.pending;
                root.pending = "";
                if (wait !== "")
                    root.probe(wait);
            }
        }
    }

    // Context for AppMenuModel; re-evaluates with the topology and desktop entries.
    function context(appId: string): var {
        Apps.revision;
        const hasApp = appId !== "";
        const entry = hasApp ? Apps.lookup(appId) : null;
        const wins = hasApp ? Compositor.toplevelsFor(appId) : [];
        const visible = wins.filter(t => !Compositor.isMinimized(t));
        // A popup holds the keyboard focus, so the active toplevel can be empty: fall back to the most recent.
        const focusedHere = wins.indexOf(Compositor.focusedToplevel) >= 0 ? Compositor.focusedToplevel : Compositor.mostRecent(visible);
        const rev = Compositor.topologyRevision;
        return {
            hasApp: hasApp,
            appName: hasApp ? Apps.nameFor(appId) : "",
            entry: entry,
            singleMain: entry ? root.singleMain[entry.id] === true : false,
            windows: wins.map(t => ({ref: t, title: t.title, focused: t === focusedHere, minimized: Compositor.isMinimized(t)})),
            focusedWindow: focusedHere,
            fullscreen: focusedHere ? focusedHere.fullscreen : false,
            maximized: focusedHere ? focusedHere.maximized : false,
            windowSpaceId: focusedHere ? Compositor.spaceOf(focusedHere) : 0,
            othersCount: hasApp ? Compositor.othersCount(appId, rev) : 0,
            hiddenCount: Compositor.hiddenWindows(rev).length,
            spaces: Compositor.spacesOn(Compositor.focusedScreenName, rev).map(s => ({id: s.id})),
            newSpaceId: Compositor.nextSpaceId()
        };
    }

    // Performs a menu item chosen from the app, File or Window menu.
    function run(item: var, appId: string, ctx: var): void {
        const entry = ctx.entry;
        switch (item.id) {
        case "about":
            Popups.openCentered("appabout", {appId: appId});
            return;
        case "hide":
            Compositor.hideApp(appId);
            break;
        case "hideOthers":
            Compositor.hideOthers(appId);
            break;
        case "showAll":
            Compositor.showAll();
            break;
        case "quit":
            Compositor.toplevelsFor(appId).forEach(t => Compositor.close(t));
            break;
        case "newWindow":
            if (entry) {
                const acts = entry.actions ? entry.actions : [];
                const act = acts.find(a => a.id === "new-window");
                if (act)
                    act.execute();
                else
                    entry.execute();
            }
            break;
        case "entryAction":
            if (entry && entry.actions[item.index])
                entry.actions[item.index].execute();
            break;
        case "minimize":
            Compositor.minimize(ctx.focusedWindow);
            break;
        case "zoom":
            Compositor.toggleZoom(ctx.focusedWindow);
            break;
        case "fullscreen":
            Compositor.toggleFullscreen(ctx.focusedWindow);
            break;
        case "moveTo":
        case "moveToNew":
            Compositor.moveToplevelToSpace(ctx.focusedWindow, item.space);
            break;
        case "bringAll":
            Compositor.bringAllToFront(appId);
            break;
        case "window":
            Compositor.activate(item.ref);
            break;
        }
        Popups.close();
    }
}
