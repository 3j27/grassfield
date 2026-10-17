import QtQuick
import Grassfield.Ui
import qs.security.lock
import qs.services

// Grassfield menu (leaf mark): About, Force Quit, Sleep/Restart/Shut Down, Lock Screen, Log Out.
// System Settings is a placeholder until M4. Lock Screen engages the session lock.
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
        {id: "lock", text: qsTr("Lock Screen")},
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
