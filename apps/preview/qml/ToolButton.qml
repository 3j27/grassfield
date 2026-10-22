import QtQuick
import Grassfield.Ui

// Toolbar button: a Preview glyph (`glyph`, see Glyph.qml) or, without one, the short `text`. `label` is the accessible name.
// `checked` draws the pressed-in state of a toggle (sidebar, info). Dimmed when disabled; the keyboard focus ring is visible.
Item {
    id: root

    property string glyph: ""
    property string text: ""
    property string label: ""
    property bool checked: false
    property bool checkable: false

    signal clicked

    readonly property color foreground: Appearance.colors.text

    implicitWidth: root.glyph !== "" ? Tokens.previewToolbarButtonSize : Math.max(Tokens.previewToolbarButtonSize, caption.implicitWidth + 2 * Tokens.spacingSm)
    implicitHeight: Tokens.previewToolbarButtonSize
    width: implicitWidth
    height: implicitHeight
    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    activeFocusOnTab: true
    Accessible.role: root.checkable ? Accessible.CheckBox : Accessible.Button
    Accessible.name: root.label !== "" ? root.label : root.text
    Accessible.checkable: root.checkable
    Accessible.checked: root.checked
    Accessible.focusable: true
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.enabled)
                root.clicked();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * Tokens.materialHoverActiveFactor)
             : (mouse.containsMouse && root.enabled ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent
    }

    Glyph {
        visible: root.glyph !== ""
        anchors.centerIn: parent
        kind: root.glyph
        color: root.foreground
    }

    Text {
        id: caption
        visible: root.glyph === ""
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.text
        color: root.foreground
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        onClicked: root.clicked()
    }
}
