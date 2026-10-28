import QtQuick
import Grassfield.Ui

// Bluetooth > Forget This Device…: the confirmation (macOS asks before it removes a paired device).
Sheet {
    id: root

    property var device: null

    signal forget(var device)

    title: root.device ? qsTr("Forget “%1”?").arg(root.device.name) : ""
    message: qsTr("The device is removed from this computer. To use it again, pair it again.")
    confirmText: qsTr("Forget Device")
    destructive: true

    function openFor(device: var): void {
        root.device = device;
        root.open();
    }

    onAccepted: root.forget(root.device)
}
