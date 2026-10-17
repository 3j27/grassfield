pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.platform
import qs.services

// One of an application's own menus (T1/T2), opened from its title in the menu bar (popup kind "appbridge",
// payload {dbusId, window, title}). Items come from grassfield-menu-bridge through MenuBridge; choosing one runs the
// application's own action (DBusMenu Event "clicked"). Toggles and radio items show a check mark when on, disabled
// items are dimmed, shortcuts are the application's.
PopupMenu {
    id: root

    readonly property int dbusId: Popups.data.dbusId !== undefined ? Popups.data.dbusId : -1
    readonly property string window: Popups.data.window !== undefined ? Popups.data.window : ""
    readonly property string title: Popups.data.title !== undefined ? Popups.data.title : ""
    // Submenus announced with about-to-show while this menu is open (once each).
    property var shown: ({})
    // Items of the open submenu when it opened, to notice a new revision that changed them.
    property string openSubmenuJson: ""

    accessibleName: qsTr("%1 menu").arg(root.title)
    currentIndex: -1
    model: MenuBridge.window === root.window ? MenuBridge.popupModel(root.dbusId, MenuBridge.revision) : []

    function submenuJson(index: int): string {
        const item = index >= 0 ? root.model[index] : null;
        return item && item.submenu ? JSON.stringify(item.submenu) : "";
    }

    // Another title of the same app was chosen: the same popup now shows another menu.
    onDbusIdChanged: {
        root.shown = {};
        root.openIndex = -1;
        root.currentIndex = -1;
    }

    onCloseRequested: Popups.close()
    onActivated: item => {
        MenuBridge.activate(item.dbusId);
        Popups.close();
    }

    // A first-level submenu opens: tell the application, which may fill or update it (AboutToShow).
    onOpenIndexChanged: {
        root.openSubmenuJson = submenuJson(root.openIndex);
        const item = root.openIndex >= 0 ? root.model[root.openIndex] : null;
        if (!item || item.dbusId === undefined || root.shown[item.dbusId])
            return;
        root.shown[item.dbusId] = true;
        MenuBridge.aboutToShow(item.dbusId);
    }

    // A new revision changed the open submenu's items: reopen it so it shows them.
    onModelChanged: {
        const index = root.openIndex;
        if (index < 0 || submenuJson(index) === root.openSubmenuJson)
            return;
        root.openIndex = -1;
        Qt.callLater(() => {
            root.openIndex = index;
        });
    }

    Component.onCompleted: MenuBridge.popup = root
    Component.onDestruction: {
        if (MenuBridge.popup === root)
            MenuBridge.popup = null;
    }
}
