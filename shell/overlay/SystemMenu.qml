import QtQuick
import Grassfield.Ui
import qs.services

// Grassfield menu (leaf mark): About, Force Quit, Sleep/Restart/Shut Down, Log Out.
// System Settings and Lock Screen are placeholders until M4 and M2.
PopupMenu {
    id: root

    accessibleName: qsTr("Grassfield menu")
    currentIndex: -1

    model: [
        {id: "about", text: qsTr("About This Computer")},
        {separator: true},
        // PLACEHOLDER (M4): no System Settings app exists yet.
        {id: "settings", text: qsTr("System Settings… (coming in M4)"), enabled: false},
        {separator: true},
        {id: "forcequit", text: qsTr("Force Quit…")},
        {separator: true},
        {id: "sleep", text: qsTr("Sleep")},
        {id: "restart", text: qsTr("Restart…")},
        {id: "shutdown", text: qsTr("Shut Down…")},
        {separator: true},
        // PLACEHOLDER (M2 security): the lock screen module is not built yet.
        {id: "lock", text: qsTr("Lock Screen (coming in M2)"), enabled: false},
        {id: "logout", text: qsTr("Log Out %1…").arg(SystemInfo.user)}
    ]

    onCloseRequested: Popups.close()

    onActivated: item => {
        switch (item.id) {
        case "about":
            Popups.openCentered("about", {});
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
        case "logout":
            Popups.confirm(qsTr("Are you sure you want to quit all applications and log out %1?").arg(SystemInfo.user), qsTr("Open applications will be closed."), qsTr("Log Out"), "logout", {}, true);
            break;
        default:
            Popups.close();
        }
    }
}
