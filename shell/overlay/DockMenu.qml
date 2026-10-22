import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../dock/DockModel.js" as DockModel
import "../dock/Launch.js" as Launch
import "../services/AppLaunch.js" as AppLaunch

// Dock item context menu. Payload (Popups.data): key, entry (DesktopEntry or null),
// pinned, fixed (the Files tile), running, windows (toplevel handles). Keep in Dock / Remove from Dock persist to grassfield.json.
PopupMenu {
    id: root

    readonly property var info: Popups.data
    readonly property var entry: info.entry ? info.entry : null
    readonly property var desktopActions: entry && entry.actions ? entry.actions : []
    // Open at Login: whether the autostart file of this app exists (checked once when the menu opens).
    property bool autostart: false
    readonly property string autostartPath: entry ? AppLaunch.autostartFile(AppLaunch.autostartDir(Apps.devSession, Apps.appsHome, Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME")), entry.id) : ""

    accessibleName: qsTr("Dock item menu")
    currentIndex: -1

    // The app's windows (only the windows of this tile: the same identity rules as the running dot), most recent first.
    readonly property var windowRows: Launch.menuWindows((info.windows ? info.windows : []).map(t => {
        const w = Compositor.windowInfo(t);
        return {ref: t, title: t.title, minimized: w.minimized, stamp: w.stamp};
    }), Tokens.menuWindowTitleMax, Apps.nameFor(appId()))

    readonly property bool isTrash: info.kind === "trash"

    model: {
        // macOS Trash menu: Open, Empty Trash… (disabled while the Trash is empty).
        if (isTrash)
            return [{id: "trashOpen", text: qsTr("Open")}, {id: "trashEmpty", text: qsTr("Empty Trash…"), enabled: !Trash.empty}];
        const items = [];
        // macOS: the app's windows come first (a check on the front window, a mark on minimized ones), then a separator.
        if (windowRows.length > 0) {
            for (const w of windowRows)
                items.push({id: "window", ref: w.ref, text: w.minimized ? qsTr("%1 (minimized)").arg(w.title) : w.title, checked: w.checked});
            items.push({separator: true});
        }
        items.push(info.running ? {id: "new", text: qsTr("New Window"), enabled: entry !== null} : {id: "open", text: qsTr("Open"), enabled: entry !== null});
        if (desktopActions.length > 0) {
            items.push({separator: true});
            for (let i = 0; i < desktopActions.length; i++)
                items.push({id: "action", index: i, text: desktopActions[i].name});
        }
        items.push({separator: true});
        items.push({
            id: "options",
            text: qsTr("Options"),
            submenu: root.optionItems()
        });
        items.push({separator: true});
        items.push({id: "showall", text: qsTr("Show All Windows"), enabled: info.running === true});
        // Option (Alt) variants, live while the menu is open (macOS): Hide becomes Hide Others, Quit becomes Force Quit.
        if (altHeld) {
            items.push({id: "hideOthers", text: qsTr("Hide Others"), enabled: info.running === true && Compositor.othersCount(appId(), Compositor.topologyRevision) > 0});
            items.push({id: "forcequit", text: qsTr("Force Quit"), enabled: info.running === true});
        } else {
            items.push({id: "hide", text: qsTr("Hide"), enabled: info.running === true});
            items.push({id: "quit", text: qsTr("Quit"), enabled: info.running === true});
        }
        return items;
    }

    // Options submenu (macOS): a running app has "Keep in Dock" (checked when kept; unchecking removes it once the app quits);
    // a kept app that is not running has "Remove from Dock" and no "Keep in Dock"; a recent app that is not kept has "Keep in Dock".
    function optionItems(): var {
        const items = [];
        // The fixed Files tile (like the Finder's) is always in the Dock: no Keep or Remove, and no "Show in Files" on Files itself.
        if (info.fixed !== true) {
            if (info.running === true || info.pinned !== true)
                items.push({id: "keep", text: qsTr("Keep in Dock"), checked: info.pinned === true, enabled: info.pinned === true || entry !== null});
            else
                items.push({id: "remove", text: qsTr("Remove from Dock")});
        }
        items.push({id: "login", text: qsTr("Open at Login"), checked: autostart, enabled: entry !== null});
        if (info.fixed !== true)
            items.push({id: "reveal", text: qsTr("Show in Files"), enabled: entry !== null});
        return items;
    }

    function lookupFn(id: string): var {
        return Apps.lookup(id);
    }

    function appId(): string {
        const w = info.windows && info.windows.length > 0 ? info.windows[0] : null;
        return w ? w.appId : "";
    }

    onCloseRequested: Popups.close()

    // Tail pointing at the icon (reference: rounded panel with a tail on the shelf side). The Overlay centres the menu on
    // the icon and keeps it Tokens.panelPopupMargin inside the window: the tail follows the icon when that clamps it.
    Shape {
        readonly property real menuX: Math.max(Tokens.panelPopupMargin, Math.min(root.Window.width - root.width - Tokens.panelPopupMargin, Popups.anchorX - root.width / 2))
        readonly property real tipX: Math.max(Tokens.radiusMenu + Tokens.dockMenuTailWidth / 2, Math.min(root.width - Tokens.radiusMenu - Tokens.dockMenuTailWidth / 2, Popups.anchorX - menuX))
        x: tipX - Tokens.dockMenuTailWidth / 2
        y: root.height - 1
        width: Tokens.dockMenuTailWidth
        height: Tokens.dockMenuTailHeight + 1
        preferredRendererType: Shape.CurveRenderer
        Accessible.ignored: true

        ShapePath {
            strokeWidth: 0
            fillColor: Appearance.withAlpha(Appearance.colors.materialTint, Appearance.tintAlpha(Appearance.effectiveTransparency))
            startX: 0
            startY: 0
            PathLine {
                x: Tokens.dockMenuTailWidth
                y: 0
            }
            PathLine {
                x: Tokens.dockMenuTailWidth / 2
                y: Tokens.dockMenuTailHeight + 1
            }
            PathLine {
                x: 0
                y: 0
            }
        }
    }

    Component.onCompleted: {
        if (autostartPath !== "")
            autostartCheck.running = true;
        // Windows opened after the shell started have no process id until Hyprland's list is read again (Force Quit needs it).
        if (info.running === true)
            Compositor.refreshToplevels();
    }

    Process {
        id: autostartCheck
        command: ["test", "-f", root.autostartPath]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.autostart = code === 0;
        }
    }

    // The autostart file is written or removed (a plain desktop file; the isolated config home in a dev session) and the
    // executable's folder revealed by Apps (Apps.writeAutostart / removeAutostart / revealExecutable): this menu is destroyed
    // by Popups.close() the moment an item is chosen, which would kill a Process it owned before it finished.

    onActivated: item => {
        const data = root.info;
        const appId = root.appId();
        // A window chosen from the list is the focus the user wants: nothing hands it back to the previous window.
        if (item.id === "window")
            FocusReturn.skip();
        // Force Quit asks first (the same confirmation and kill path as the Grassfield menu's Force Quit…): the confirmation
        // replaces this menu, nothing is killed before its button.
        // Empty Trash asks first, macOS wording, destructive (Cancel has the focus). The Trash it empties is the isolated one in dev.
        if (item.id === "trashEmpty") {
            Popups.confirm(qsTr("Are you sure you want to permanently erase the items in the Trash?"), qsTr("You can’t undo this action."), qsTr("Empty Trash"), "emptytrash", {}, true);
            return;
        }
        if (item.id === "forcequit") {
            const pids = Launch.forceQuitPids(data.windows.map(t => Compositor.pidOf(t)));
            if (pids.length === 0) {
                console.warn("grassfield-shell: force quit refused, no process id for", appId);
                Popups.close();
                return;
            }
            Popups.confirm(qsTr("Force quit “%1”?").arg(Apps.nameFor(appId)), qsTr("Unsaved changes in this application will be lost."), qsTr("Force Quit"), "forcequit", {pid: pids[0], pids: pids}, true);
            return;
        }
        Popups.close();
        switch (item.id) {
        case "trashOpen":
            Trash.open();
            Trash.refresh();
            break;
        case "window":
            // Restores a minimized window and switches to its Desktop (the same call as a Dock click).
            Compositor.activate(item.ref);
            break;
        case "open":
        case "new":
            if (data.entry)
                Apps.launch(data.entry);
            break;
        case "action":
            Apps.launch(data.entry.actions[item.index]);
            break;
        case "remove":
            Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, data.key, root.lookupFn));
            break;
        case "keep":
            if (data.pinned)
                Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, data.key, root.lookupFn));
            else
                Settings.setDockPinned(DockModel.pin(Settings.dockPinned, data.key));
            break;
        case "login":
            // Refused (nothing written or removed) for an id that is not a plain file name or a hostile command.
            if (root.autostartPath !== "" && root.autostart)
                Apps.removeAutostart(root.autostartPath);
            else if (root.autostartPath !== "" && AppLaunch.autostartText(data.entry) !== "")
                Apps.writeAutostart(root.autostartPath, AppLaunch.autostartText(data.entry));
            break;
        case "reveal":
            Apps.revealExecutable(data.entry.command && data.entry.command.length > 0 ? data.entry.command[0] : "");
            break;
        case "showall":
            if (appId !== "")
                Compositor.bringAllToFront(appId);
            break;
        case "hide":
            if (appId !== "")
                Compositor.hideApp(appId);
            break;
        case "hideOthers":
            if (appId !== "")
                Compositor.hideOthers(appId);
            break;
        case "quit":
            data.windows.forEach(t => Compositor.close(t));
            break;
        }
    }
}
