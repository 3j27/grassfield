import QtQuick
import Grassfield.Ui

// One device of the Bluetooth pane (macOS 27): its glyph, its name and, for a paired device, a status line ("Connected · 80 %"
// with the battery) and an (i) button; a nearby device has a Connect button instead. A paired row itself connects or
// disconnects (a click, Space or Return: activated). Placed as measured (docs/audits/settings-parity-2026-10-26.md § Bluetooth);
// a 1-pt separator above every row but the first.
Item {
    id: root

    property string title: ""
    property string status: ""
    // A glyph of the shared set (System.btGlyph).
    property string glyph: "bluetooth"
    // Percent, -1 when unknown.
    property int battery: -1
    property bool nearby: false
    // Joining it: the Connect button waits.
    property bool busy: false

    signal activated
    signal infoRequested
    signal connectRequested

    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0
    readonly property real rowHeight: root.nearby ? Tokens.settingsWifiOtherRowHeight : Tokens.settingsDeviceRowHeight
    // The ring shows for the keyboard's focus only, as a control's visualFocus (PrinterRow): a click focuses the row without it.
    property bool clickFocused: false
    readonly property bool visualFocus: root.activeFocus && !root.clickFocused

    width: parent ? parent.width : implicitWidth
    implicitHeight: root.contentTop + root.rowHeight
    activeFocusOnTab: !root.nearby
    onActiveFocusChanged: if (!root.activeFocus)
        root.clickFocused = false
    Accessible.role: root.nearby ? Accessible.StaticText : Accessible.Button
    Accessible.name: root.title
    Accessible.description: root.status
    Accessible.focusable: !root.nearby
    Accessible.onPressAction: if (!root.nearby)
        root.activated()

    Keys.onPressed: event => {
        if (!root.nearby && ActivationKeys.activation(event.key)) {
            root.activated();
            event.accepted = true;
        }
    }

    Rectangle {
        visible: root.contentTop > 0
        x: Tokens.settingsRowInset
        width: parent.width - 2 * Tokens.settingsRowInset
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // The keyboard focus: a ring inside the row.
    Rectangle {
        x: Tokens.controlFocusOutline / 2
        y: root.contentTop + Tokens.controlFocusOutline / 2
        width: parent.width - Tokens.controlFocusOutline
        height: root.rowHeight - Tokens.controlFocusOutline
        visible: root.visualFocus
        radius: Tokens.radiusMenu
        color: "transparent"
        border.width: Tokens.controlFocusOutline
        border.color: Appearance.focusRingColor
    }

    MouseArea {
        anchors.fill: parent
        enabled: !root.nearby
        onClicked: {
            root.clickFocused = true;
            root.forceActiveFocus();
            root.activated();
        }
    }

    Icon {
        x: Tokens.settingsDeviceGlyphInset
        y: root.contentTop + (root.rowHeight - height) / 2
        name: root.glyph
        size: Tokens.settingsDeviceGlyphSize
        color: Appearance.windowSecondary
    }

    Text {
        id: nameText
        textFormat: Text.PlainText
        x: Tokens.settingsDeviceTextInset
        y: root.nearby ? root.contentTop + (root.rowHeight - height) / 2 : root.contentTop + Tokens.settingsDeviceNameBaseline - baselineOffset
        width: (root.nearby ? connect.x : info.x) - Tokens.spacingSm - x
        elide: Text.ElideRight
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Row {
        visible: !root.nearby
        x: Tokens.settingsDeviceTextInset
        y: root.contentTop + Tokens.settingsDeviceStatusBaseline - statusText.baselineOffset
        spacing: Tokens.spacingXs

        Text {
            id: statusText
            textFormat: Text.PlainText
            text: root.status
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        // "Connected – [battery] 80 %", as macOS writes it.
        Text {
            textFormat: Text.PlainText
            visible: root.battery >= 0
            text: "\u2013"
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Icon {
            visible: root.battery >= 0
            anchors.verticalCenter: statusText.verticalCenter
            name: "battery"
            size: Tokens.settingsWifiGlyphSize
            color: Appearance.windowSecondary
        }

        Text {
            textFormat: Text.PlainText
            visible: root.battery >= 0
            text: qsTr("%1 %").arg(root.battery)
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }

    InfoButton {
        id: info
        visible: !root.nearby
        x: root.width - width - Tokens.settingsInfoInset
        y: root.contentTop + Tokens.settingsInfoTop
        accessibleName: qsTr("Details of %1").arg(root.title)
        onClicked: root.infoRequested()
    }

    Button {
        id: connect
        visible: root.nearby
        push: true
        enabled: !root.busy
        text: root.busy ? qsTr("Connecting…") : qsTr("Connect")
        Accessible.name: qsTr("Connect %1").arg(root.title)
        x: root.width - width - Tokens.settingsRowInset
        y: root.contentTop + (root.rowHeight - height) / 2
        onClicked: root.connectRequested()
    }
}
