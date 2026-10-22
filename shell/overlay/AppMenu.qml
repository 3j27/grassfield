import QtQuick
import Grassfield.Ui
import qs.menubar
import qs.services

// Application menus (T0): the app-name menu, File and Window, selected by the popup kind
// (app | appfile | appwindow). Items come from AppMenuModel and run through AppMenus.run().
PopupMenu {
    id: root

    // Captured when the menu opens: layer-shell focus may clear the active toplevel.
    readonly property string appId: Popups.data.appId ? Popups.data.appId : ""
    readonly property var ctx: AppMenus.context(appId)

    accessibleName: Popups.kind === "appfile" ? qsTr("File menu") : (Popups.kind === "appwindow" ? qsTr("Window menu") : qsTr("Application menu"))
    currentIndex: -1

    model: {
        switch (Popups.kind) {
        case "appfile":
            return AppMenus.model.fileMenu(ctx);
        case "appwindow":
            return AppMenus.model.windowMenu(ctx);
        }
        return AppMenus.model.appMenu(ctx);
    }

    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)
    onActivated: item => AppMenus.run(item, appId, ctx)
}
