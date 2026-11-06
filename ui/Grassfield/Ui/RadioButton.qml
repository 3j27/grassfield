import QtQuick
import QtQuick.Templates as T

// Radio button (QtQuick.Templates RadioButton): a disc as big as a check box (control.checkBoxSize, its caption as far: one size
// for both, UI audit 2026-11-05 LOW), accent with a centre dot when checked, caption on its
// right. Siblings under one parent are exclusive (autoExclusive, as the template); a checked one is not unchecked by a click.
T.RadioButton {
    id: root

    property string accessibleName: ""
    // Checked: the accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)
    // Not key, a checked radio button keeps its plain look and its dot takes the text colour (macOS 27).
    readonly property bool accentFill: root.checked && root.keyLook

    // Whole pixels, so that the next control in a row stays on the pixel grid.
    implicitWidth: Math.ceil(Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding))
    implicitHeight: Math.max(Tokens.controlButtonHeight, implicitContentHeight + topPadding + bottomPadding)
    // Whole device pixels, as CheckBox: the measured gap (5.5) would start the label between two pixels at scale 1.
    readonly property real pixelRatio: Math.max(1, Screen.devicePixelRatio)
    leftPadding: Math.round((Tokens.controlCheckBoxSize + Tokens.controlCheckBoxGap) * root.pixelRatio) / root.pixelRatio
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
        const at = mine.indexOf(root);
        const target = at < 0 ? null : mine[at + direction];
        if (target) {
            target.forceActiveFocus(Qt.TabFocusReason);
            target.click();
        }
    }

    Keys.onPressed: event => {
        const arrows = ActivationKeys.navigation(event.key);
        if (!root.visible || !root.enabled) {
            if (arrows || ActivationKeys.activation(event.key))
                event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
            root.step(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
            root.step(-1);
            event.accepted = true;
        }
    }

    FocusGuard {}

    indicator: Rectangle {
        x: 0
        y: (root.height - height) / 2
        width: Tokens.controlCheckBoxSize
        height: Tokens.controlCheckBoxSize
        radius: width / 2
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

        Rectangle {
            anchors.centerIn: parent
            // Whole pixels, with the parity of the disc so that it centres on the grid: a sharp dot.
            width: Math.round(parent.width / 3) + (parent.width - Math.round(parent.width / 3)) % 2
            height: width
            radius: width / 2
            color: root.accentFill ? Appearance.colors.selectionText : Appearance.colors.text
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
        opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }
}
