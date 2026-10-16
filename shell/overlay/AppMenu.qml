import QtQuick
import Grassfield.Ui
import qs.platform
import qs.services

// Application menu, T0-lite (works today for any app): About, Hide, Quit. The full T0 menu
// (Hide Others, Show All, Services, ...) is M2 work, see docs/specs/menubar.md.
PopupMenu {
    id: root

    // Captured when the menu opens: layer-shell focus may clear the active toplevel.
    readonly property string appId: Popups.data.appId ? Popups.data.appId : ""
    readonly property string appName: appId === "" ? "" : Apps.nameFor(appId)
    readonly property bool hasApp: appId !== ""

    accessibleName: qsTr("Application menu")
    currentIndex: -1

    model: [
        {id: "about", text: hasApp ? qsTr("About %1").arg(appName) : qsTr("About Desktop"), enabled: hasApp},
        {separator: true},
        {id: "hide", text: hasApp ? qsTr("Hide %1").arg(appName) : qsTr("Hide"), enabled: hasApp},
        {separator: true},
        {id: "quit", text: hasApp ? qsTr("Quit %1").arg(appName) : qsTr("Quit"), enabled: hasApp}
    ]

    onCloseRequested: Popups.close()

    onActivated: item => {
        const id = appId;
        switch (item.id) {
        case "about":
            Popups.openCentered("appabout", {appId: id});
            return;
        case "hide":
            Compositor.toplevelsFor(id).forEach(t => Compositor.hide(t));
            break;
        case "quit":
            Compositor.toplevelsFor(id).forEach(t => Compositor.close(t));
            break;
        }
        Popups.close();
    }
}
