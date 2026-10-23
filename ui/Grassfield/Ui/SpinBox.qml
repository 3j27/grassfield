import QtQuick
import QtQuick.Templates as T

// Number field with a stepper (QtQuick.Templates SpinBox): the value in an editable field and the up/down arrows of the
// AppKit stepper on its right. Up/Down arrows and the wheel step it, Page keys step by ten, the field takes typed digits
// (`editable`). `valueModified()` reports a user change.
T.SpinBox {
    id: root

    property string accessibleName: ""

    implicitWidth: Math.max(Tokens.controlButtonMinWidth, contentItem.implicitWidth + leftPadding + rightPadding)
    implicitHeight: Tokens.controlFieldHeight
    leftPadding: Tokens.spacingSm
    rightPadding: Tokens.controlStepperWidth + Tokens.spacingXs
    editable: true
    wheelEnabled: true
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.SpinBox
    Accessible.name: root.accessibleName

    // Page Up / Page Down step by ten, as AppKit.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            const direction = event.key === Qt.Key_PageUp ? 1 : -1;
            root.value = Math.max(root.from, Math.min(root.to, root.value + 10 * direction * root.stepSize));
            root.valueModified();
            event.accepted = true;
        }
    }

    validator: IntValidator {
        locale: root.locale.name
        bottom: Math.min(root.from, root.to)
        top: Math.max(root.from, root.to)
    }

    contentItem: TextInput {
        text: root.textFromValue(root.value, root.locale)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        color: Appearance.colors.text
        selectionColor: Appearance.highlight
        selectedTextColor: Appearance.highlightText
        horizontalAlignment: Qt.AlignLeft
        verticalAlignment: Qt.AlignVCenter
        readOnly: !root.editable
        validator: root.validator
        inputMethodHints: Qt.ImhFormattedNumbersOnly
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        Accessible.role: Accessible.EditableText
        Accessible.name: root.accessibleName

        TextCursor {}
    }

    up.indicator: Item {
        x: root.width - width
        height: root.height / 2
        width: Tokens.controlStepperWidth + Tokens.spacingXs
        opacity: root.enabled && root.value < root.to ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: Tokens.radiusControl / 2
            color: Appearance.withAlpha(Appearance.colors.hover, root.up.pressed ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.up.hovered || root.up.pressed
        }

        Icon {
            anchors.centerIn: parent
            name: "chevron-down"
            rotation: 180
            size: Tokens.controlStepperWidth - Tokens.spacingXs
            color: Appearance.colors.text
        }
    }

    down.indicator: Item {
        x: root.width - width
        y: root.height / 2
        height: root.height / 2
        width: Tokens.controlStepperWidth + Tokens.spacingXs
        opacity: root.enabled && root.value > root.from ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: Tokens.radiusControl / 2
            color: Appearance.withAlpha(Appearance.colors.hover, root.down.pressed ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.down.hovered || root.down.pressed
        }

        Icon {
            anchors.centerIn: parent
            name: "chevron-down"
            size: Tokens.controlStepperWidth - Tokens.spacingXs
            color: Appearance.colors.text
        }
    }

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast ? 1 : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        FocusRing {
            visible: root.activeFocus
        }
    }
}
