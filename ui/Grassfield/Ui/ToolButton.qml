import QtQuick
import QtQuick.Templates as T

// Toolbar button (QtQuick.Templates ToolButton): a Grassfield symbolic icon (`iconName`), any glyph the app draws (put it
// inside as a child: it is centred), or a short caption (`text`). `accessibleName` is what assistive technology reads
// (the caption when empty). `checked` draws the pressed-in state; `radio` makes a checkable button one choice of a group
// of siblings (it cannot be unchecked by clicking it; role RadioButton), otherwise a checkable button is a toggle
// (role CheckBox). A bound `checked` follows its binding after every click (the button only reports the click).
T.ToolButton {
    id: root

    property string iconName: ""
    property real iconRotation: 0
    property string accessibleName: ""
    // One choice of a group of sibling buttons.
    property bool radio: false
    // Fully rounded shape (a capsule group) instead of the control radius.
    property bool capsule: false
    // Icon and caption colour (a button on the destructive banner uses destructiveText).
    property color tint: Appearance.colors.text
    property real buttonSize: Tokens.controlToolButtonSize
    property real glyphSize: Tokens.controlToolIconSize
    // Glyphs drawn by the app (a view glyph, a theme icon): centred in the button, dimmed with it when disabled.
    default property alias glyph: slot.data

    readonly property color foreground: !enabled ? Appearance.withAlpha(root.tint, Tokens.materialDisabledOpacity) : root.tint

    implicitWidth: root.text !== "" ? Math.max(root.buttonSize, caption.implicitWidth + 2 * Tokens.spacingSm) : root.buttonSize
    implicitHeight: root.buttonSize
    autoExclusive: root.radio
    hoverEnabled: true
    // Never takes the focus by a click or by Tab: a toolbar button does not take the focus from the view it acts on, and is
    // outside the Tab chain unless Full Keyboard Access is on (macOS; that setting is not offered here). Space after a click
    // still goes to the view; code and assistive technology can still focus it.
    focusPolicy: Qt.NoFocus
    Accessible.role: root.checkable ? (root.radio ? Accessible.RadioButton : Accessible.CheckBox) : Accessible.Button
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.text
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: root.activate()
    Accessible.onToggleAction: root.activate()

    function activate(): bool {
        if (!root.visible || !root.enabled)
            return false;
        root.click();
        return true;
    }

    // Return and Enter act like Space (which the template handles itself); a hidden or disabled button that still holds the
    // focus swallows them (Space, Return, Enter, Select).
    Keys.onPressed: event => {
        const activation = ActivationKeys.activation(event.key);
        if (!root.visible || !root.enabled) {
            if (activation)
                event.accepted = true;
            return;
        }
        // Return, Enter and Select act like Space (which the template handles itself).
        if (activation && event.key !== Qt.Key_Space) {
            root.activate();
            event.accepted = true;
        }
    }

    FocusGuard {}

    background: Rectangle {
        radius: root.capsule ? height / 2 : Tokens.radiusControl
        color: root.checked ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * Tokens.materialHoverActiveFactor)
             : (root.enabled && root.down ? Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
             : (root.enabled && root.hovered ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"))
        border.width: Appearance.increaseContrast && root.checked ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    contentItem: Item {
        Icon {
            visible: root.iconName !== ""
            anchors.centerIn: parent
            name: root.iconName
            size: root.glyphSize
            color: root.foreground
            rotation: root.iconRotation
        }

        Item {
            id: slot
            anchors.fill: parent
            opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        }

        Text {
            id: caption
            textFormat: Text.PlainText
            visible: root.text !== ""
            anchors.centerIn: parent
            text: root.text
            color: root.foreground
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }

    FocusRing {
        shapeRadius: root.capsule ? root.height / 2 : Tokens.radiusControl
        visible: root.visualFocus
    }
}
