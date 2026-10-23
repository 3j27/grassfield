import QtQuick
import QtQuick.Templates as T

// Radio button (QtQuick.Templates RadioButton): a 14 px disc, accent with a centre dot when checked, caption on its
// right. Siblings under one parent are exclusive (autoExclusive, as the template); a checked one is not unchecked by a click.
T.RadioButton {
    id: root

    property string accessibleName: ""

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(Tokens.controlButtonHeight, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Tokens.controlCheckSize + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.RadioButton
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.text

    indicator: Rectangle {
        x: 0
        y: (root.height - height) / 2
        width: Tokens.controlCheckSize
        height: Tokens.controlCheckSize
        radius: width / 2
        color: root.checked ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast || !root.checked ? 1 : 0
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

        Rectangle {
            anchors.centerIn: parent
            width: parent.width / 3
            height: width
            radius: width / 2
            color: Appearance.colors.accentText
            visible: root.checked
        }

        FocusRing {
            shapeRadius: parent.radius
            visible: root.activeFocus
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
