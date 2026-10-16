import QtQuick
import Grassfield.Ui
import qs.platform
import qs.services
import "../dock/DockModel.js" as DockModel

// Dock item context menu. Payload (Popups.data): key, entry (DesktopEntry or null),
// pinned, running, windows (toplevel handles). Keep in Dock / Remove from Dock persist to grassfield.json.
PopupMenu {
    id: root

    readonly property var info: Popups.data
    readonly property var entry: info.entry ? info.entry : null
    readonly property var desktopActions: entry && entry.actions ? entry.actions : []

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
        items.push(info.pinned ? {id: "unpin", text: qsTr("Remove from Dock")} : {id: "pin", text: qsTr("Keep in Dock"), enabled: entry !== null});
        items.push({separator: true});
        items.push({id: "quit", text: qsTr("Quit"), enabled: info.running === true});
        return items;
    }

    function lookupFn(id: string): var {
        return Apps.lookup(id);
    }

    onCloseRequested: Popups.close()

    onActivated: item => {
        const data = root.info;
        Popups.close();
        switch (item.id) {
        case "open":
        case "new":
            if (data.entry)
                data.entry.execute();
            break;
        case "action":
            data.entry.actions[item.index].execute();
            break;
        case "pin":
            Settings.setDockPinned(DockModel.pin(Settings.dockPinned, data.key));
            break;
        case "unpin":
            Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, data.key, root.lookupFn));
            break;
        case "quit":
            data.windows.forEach(t => Compositor.close(t));
            break;
        }
    }
}
