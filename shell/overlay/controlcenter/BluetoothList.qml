pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter
import "Model.js" as Model

// Expanded Bluetooth section (CC2): paired devices, connect / disconnect, battery when exposed.
Column {
    id: root

    width: parent ? parent.width : implicitWidth
    spacing: Tokens.spacingXs

    Caption {
        width: parent.width
        visible: !BluetoothState.available || !BluetoothState.enabled || BluetoothState.devices.length === 0
        text: !BluetoothState.available ? qsTr("No Bluetooth adapter")
            : !BluetoothState.enabled ? qsTr("Bluetooth is off") : qsTr("No paired devices")
    }

    ListView {
        id: list
        width: parent.width
        height: Math.min(contentHeight, Tokens.panelCcListMaxRows * Tokens.panelCcRowHeight)
        clip: true
        interactive: contentHeight > height
        visible: BluetoothState.enabled
        model: BluetoothState.devices

        delegate: ListRow {
            required property var modelData

            width: list.width
            text: modelData.name
            trailing: modelData.connected ? (Model.batteryText(modelData.battery) !== "" ? Model.batteryText(modelData.battery) : qsTr("Connected")) : ""
            selected: modelData.connected
            accessibleName: [modelData.name, modelData.connected ? qsTr("connected") : qsTr("not connected"), Model.batteryText(modelData.battery)].filter(s => s !== "").join(", ")
            onActivated: BluetoothState.toggleDevice(modelData)
        }
    }
}
