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
    // A hidden or disabled control ignores every activation path, assistive technology included.
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.click()
    Accessible.onToggleAction: if (root.visible && root.enabled)
        root.click()

    // The arrow keys move to the previous or next radio button of the group (the siblings under one parent), check it and
    // give it the focus, without wrapping (macOS).
    function step(direction: int): void {
        const siblings = root.parent ? root.parent.children : [];
        const mine = [];
        for (let i = 0; i < siblings.length; i++) {
            if (siblings[i] instanceof T.RadioButton && siblings[i].visible && siblings[i].enabled)
                mine.push(siblings[i]);
        }
        const target = mine[mine.indexOf(root) + direction];
        if (target) {
            target.forceActiveFocus(Qt.TabFocusReason);
            target.click();
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
            root.step(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
            root.step(-1);
            event.accepted = true;
        }
    }

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
