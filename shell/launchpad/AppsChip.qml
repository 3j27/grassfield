import QtQuick
import Grassfield.Ui

// A category chip of the Apps panel: a capsule, accent-filled when it is the selected category, with a
// focus ring while it holds the keyboard focus.
Item {
    id: root

    required property string label
    property bool active: false
    property bool focused: false

    signal clicked

    implicitWidth: text.implicitWidth + 2 * Tokens.launcherChipPadding
    implicitHeight: Tokens.launcherChipHeight
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.checked: active
    Accessible.focused: focused
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.active ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        visible: area.containsMouse && !root.active
        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
    }

    Rectangle {
        // Keyboard focus ring: outside the capsule, accent and translucent (as macOS).
        anchors.fill: parent
        anchors.margins: -Tokens.controlFocusOutline
        radius: height / 2
        visible: root.focused
        color: "transparent"
        border.width: Tokens.controlFocusOutline
        border.color: Appearance.focusRingColor
    }

    Text {
        id: text
        anchors.centerIn: parent
        text: root.label
        textFormat: Text.PlainText
        color: root.active ? Appearance.colors.selectionText : Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: root.clicked()
    }
}
