import QtQuick
import QtQuick.Templates as T

// Check box (QtQuick.Templates CheckBox): a 16-pt box (macOS 27 Settings), accent when checked (check mark) or partially checked (minus,
// `tristate`), with the caption (`text`) on its right. The box toggles itself when clicked or on Space; `toggled()` and
// `checkStateChanged` report it. Return and Enter do not toggle (as AppKit).
T.CheckBox {
    id: root

    property string accessibleName: ""
    // Checked: the accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)
    // Not key, a checked box keeps its plain look and its mark takes the text colour (macOS 27).
    readonly property bool accentFill: root.checkState !== Qt.Unchecked && root.keyLook

    // Whole pixels, so that the next control in a row stays on the pixel grid.
    implicitWidth: Math.ceil(Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding))
    implicitHeight: Math.max(Tokens.controlButtonHeight, implicitContentHeight + topPadding + bottomPadding)
    // Whole device pixels: the measured gap (5.5) would start the label between two pixels at scale 1 (it stays 5.5 at 2x).
    readonly property real pixelRatio: Math.max(1, Screen.devicePixelRatio)
    leftPadding: Math.round((Tokens.controlCheckBoxSize + Tokens.controlCheckBoxGap) * root.pixelRatio) / root.pixelRatio
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
        width: Tokens.controlCheckBoxSize
        height: Tokens.controlCheckBoxSize
        radius: Tokens.controlCheckRadius
        color: root.accentFill ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        border.width: Appearance.increaseContrast || !root.accentFill ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1

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
            color: root.accentFill ? Appearance.colors.selectionText : Appearance.colors.text
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
        opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }
}
