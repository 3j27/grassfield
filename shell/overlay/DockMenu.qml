import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../dock/DockModel.js" as DockModel
import "../services/AppLaunch.js" as AppLaunch

// Dock item context menu. Payload (Popups.data): key, entry (DesktopEntry or null),
// pinned, running, windows (toplevel handles). Keep in Dock / Remove from Dock persist to grassfield.json.
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

    model: {
        const items = [];
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
            submenu: [
                {id: "keep", text: info.pinned ? qsTr("Remove from Dock") : qsTr("Keep in Dock"), checked: info.pinned === true, enabled: info.pinned === true || entry !== null},
                {id: "login", text: qsTr("Open at Login"), checked: autostart, enabled: entry !== null},
                {id: "reveal", text: qsTr("Show in Files"), enabled: entry !== null}
            ]
        });
        items.push({separator: true});
        items.push({id: "showall", text: qsTr("Show All Windows"), enabled: info.running === true});
        items.push({id: "hide", text: qsTr("Hide"), enabled: info.running === true});
        items.push({id: "quit", text: qsTr("Quit"), enabled: info.running === true});
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

    Component.onCompleted: if (autostartPath !== "")
        autostartCheck.running = true

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
        Popups.close();
        switch (item.id) {
        case "open":
        case "new":
            if (data.entry)
                Apps.launch(data.entry);
            break;
        case "action":
            Apps.launch(data.entry.actions[item.index]);
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
        case "quit":
            data.windows.forEach(t => Compositor.close(t));
            break;
        }
    }
}
