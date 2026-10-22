import QtQuick
import Grassfield.Ui

// Toolbar button: a Grassfield symbolic icon (`iconName`), a drawn glyph (`glyph`, see ViewGlyph) or
// a short label. `checked` draws the pressed-in state of a segmented choice.
Item {
    id: root

    property string iconName: ""
    // Freedesktop theme icon (e.g. "media-eject-symbolic"), tinted like the Grassfield icons.
    property string themeIconName: ""
    property real iconRotation: 0
    property string glyph: ""
    property string label: ""
    property string accessibleName: ""
    property bool checked: false
    property bool checkable: false

    // Glyph and label colour (a button on the destructive banner uses destructiveText).
    property color tint: Appearance.colors.text

    signal clicked

    readonly property color foreground: !enabled ? Appearance.withAlpha(root.tint, Tokens.materialDisabledOpacity) : root.tint

    implicitWidth: label !== "" ? labelText.implicitWidth + 2 * Tokens.spacingSm : Tokens.filesToolbarButtonSize
    implicitHeight: Tokens.filesToolbarButtonSize
    activeFocusOnTab: true
    Accessible.role: root.checkable ? Accessible.RadioButton : Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.checkable: root.checkable
    Accessible.checked: root.checked
    Accessible.focusable: true
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.clicked();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: root.checked ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 1.5)
             : mouse.containsMouse && root.enabled ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent
    }

    Icon {
        visible: root.iconName !== ""
        anchors.centerIn: parent
        name: root.iconName
        size: Tokens.filesToolbarIconSize
        color: root.foreground
        rotation: root.iconRotation
    }

    ThemeIcon {
        visible: root.themeIconName !== ""
        anchors.centerIn: parent
        name: root.themeIconName
        size: Tokens.filesToolbarIconSize
        tint: true
        color: root.foreground
    }

    ViewGlyph {
        visible: root.glyph !== ""
        anchors.centerIn: parent
        kind: root.glyph
        size: Tokens.filesToolbarIconSize
        color: root.foreground
    }

    Text {
        id: labelText
        textFormat: Text.PlainText
        visible: root.label !== ""
        anchors.centerIn: parent
        text: root.label
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
