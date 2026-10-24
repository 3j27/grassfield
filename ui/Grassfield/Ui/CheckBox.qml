import QtQuick
import QtQuick.Templates as T

// Check box (QtQuick.Templates CheckBox): a 14 px box, accent when checked (check mark) or partially checked (minus,
// `tristate`), with the caption (`text`) on its right. The box toggles itself when clicked or on Space; `toggled()` and
// `checkStateChanged` report it. Return and Enter do not toggle (as AppKit).
T.CheckBox {
    id: root

    property string accessibleName: ""

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(Tokens.controlButtonHeight, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Tokens.controlCheckSize + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.text
    // A hidden or disabled control ignores every activation path, assistive technology included.
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.click()
    Accessible.onToggleAction: if (root.visible && root.enabled)
        root.click()

    // A hidden or disabled control that still holds the focus ignores its activation keys.
    Keys.onPressed: event => {
        if ((!root.visible || !root.enabled) && (ActivationKeys.activation(event.key)))
            event.accepted = true;
    }

    FocusGuard {}

    indicator: Rectangle {
        x: 0
        y: (root.height - height) / 2
        width: Tokens.controlCheckSize
        height: Tokens.controlCheckSize
        radius: Tokens.controlCheckRadius
        color: root.checkState !== Qt.Unchecked ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast || root.checkState === Qt.Unchecked ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, root.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.enabled && (root.hovered || root.down)
        }

        Icon {
            anchors.centerIn: parent
            name: root.checkState === Qt.PartiallyChecked ? "minimize-glyph" : "checkmark"
            size: parent.width - 2 * Tokens.controlCheckMarkInset
            color: Appearance.colors.accentText
            visible: root.checkState !== Qt.Unchecked
        }

        FocusRing {
            shapeRadius: Tokens.controlCheckRadius
            visible: root.visualFocus
        }
    }

    contentItem: Text {
        textFormat: Text.PlainText
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root.text
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }
}
