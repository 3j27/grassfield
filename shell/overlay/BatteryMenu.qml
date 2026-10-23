import QtQuick
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.services

// Battery status menu: percentage and time remaining from UPower.
PopupMenu {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property real percent: device ? Math.round(device.percentage * 100) : 0
    readonly property bool charging: device !== null && device.state === UPowerDeviceState.Charging
    readonly property bool full: device !== null && device.state === UPowerDeviceState.FullyCharged

    function duration(seconds: real): string {
        const minutes = Math.round(seconds / 60);
        return minutes >= 60 ? qsTr("%1:%2").arg(Math.floor(minutes / 60)).arg(String(minutes % 60).padStart(2, "0")) : qsTr("0:%1").arg(String(minutes).padStart(2, "0"));
    }

    readonly property string detail: {
        if (!device)
            return "";
        if (full)
            return qsTr("Fully charged");
        if (charging)
            return device.timeToFull > 0 ? qsTr("Time until full: %1").arg(duration(device.timeToFull)) : qsTr("Charging");
        return device.timeToEmpty > 0 ? qsTr("Time remaining: %1").arg(duration(device.timeToEmpty)) : qsTr("On battery power");
    }

    accessibleName: qsTr("Battery")
    currentIndex: -1

    model: [
        {id: "level", text: qsTr("Battery: %1%").arg(percent), enabled: false},
        {id: "detail", text: detail, enabled: false}
    ]

    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)
    onActivated: Popups.close()
}
