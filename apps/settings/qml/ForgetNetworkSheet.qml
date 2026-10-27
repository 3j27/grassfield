import QtQuick
import Grassfield.Ui

// Wi-Fi > Forget This Network…: the confirmation (macOS asks before it removes a known network and its password).
Sheet {
    id: root

    property var net: null

    signal forget(var net)

    title: root.net ? qsTr("Forget Wi-Fi network “%1”?").arg(root.net.label) : ""
    message: qsTr("This computer will no longer join this network on its own, and its saved password is removed.")
    confirmText: qsTr("Forget")
    destructive: true

    function openFor(net: var): void {
        root.net = net;
        root.open();
    }

    onAccepted: root.forget(root.net)
}
