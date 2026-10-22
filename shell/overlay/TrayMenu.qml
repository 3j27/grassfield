pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.menubar
import qs.services

// A status item's own menu (popup kind "tray", payload {item}): the DBusMenu the application exports, drawn with the same
// PopupMenu as the bar's other menus. Choosing a row triggers the application's entry.
PopupMenu {
    id: root

    readonly property var trayItem: Popups.data.item !== undefined ? Popups.data.item : null
    // The item went away (the app quit or crashed) while its menu was open: nothing to act on.
    readonly property bool alive: TrayHost.alive(root.trayItem)

    accessibleName: qsTr("%1 menu").arg(root.trayItem ? root.trayItem.title : "")
    currentIndex: -1
    model: node.rows

    onAliveChanged: {
        if (!root.alive)
            Qt.callLater(Popups.close);
    }
    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)
    onActivated: item => {
        if (item.entry)
            item.entry.triggered();
        Popups.close();
    }

    TrayMenuNode {
        id: node
        handle: root.trayItem ? root.trayItem.menu : null
    }
}
