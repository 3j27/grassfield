import QtQuick
import Quickshell
import Grassfield.Ui
import qs.security.lock
import qs.services

// Grassfield menu (leaf mark): About, Force Quit, Sleep/Restart/Shut Down, Lock Screen, Log Out.
// System Settings launches grassfield-settings (GRASSFIELD_SETTINGS_CMD overrides it in dev). Lock Screen engages the session lock.
PopupMenu {
    id: root

    accessibleName: qsTr("Grassfield menu")
    currentIndex: -1

    model: [
        {id: "about", text: qsTr("About This Computer")},
        {separator: true},
        {id: "settings", text: qsTr("System Settings…")},
        {separator: true},
        {id: "forcequit", text: qsTr("Force Quit…")},
        {separator: true},
        {id: "sleep", text: qsTr("Sleep")},
        {id: "restart", text: qsTr("Restart…")},
        {id: "shutdown", text: qsTr("Shut Down…")},
        {separator: true},
        {id: "lock", text: qsTr("Lock Screen")},
        {id: "logout", text: qsTr("Log Out %1…").arg(SystemInfo.user)}
    ]

    onCloseRequested: Popups.close()

    onActivated: item => {
        switch (item.id) {
        case "about":
            Popups.openCentered("about", {});
            break;
        case "settings":
            Quickshell.execDetached((Quickshell.env("GRASSFIELD_SETTINGS_CMD") || "grassfield-settings").split(" "));
            Popups.close();
            break;
        case "forcequit":
            Popups.openCentered("forcequit", {});
            break;
        case "sleep":
            Popups.close();
            Power.sleepNow();
            break;
        case "restart":
            Popups.confirm(qsTr("Are you sure you want to restart your computer now?"), qsTr("Open applications will be closed."), qsTr("Restart"), "restart", {}, true);
            break;
        case "shutdown":
            Popups.confirm(qsTr("Are you sure you want to shut down your computer now?"), qsTr("Open applications will be closed."), qsTr("Shut Down"), "shutdown", {}, true);
            break;
        case "lock":
            Popups.close();
            Lock.lock("menu");
            break;
        case "logout":
            Popups.confirm(qsTr("Are you sure you want to quit all applications and log out %1?").arg(SystemInfo.user), qsTr("Open applications will be closed."), qsTr("Log Out"), "logout", {}, true);
            break;
        default:
            Popups.close();
        }
    }
}
