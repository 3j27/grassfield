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
        if (!root.visible || !root.enabled) {
            event.accepted = !ActivationKeys.propagates(event.key);
            return;
        }
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            const direction = event.key === Qt.Key_PageUp ? 1 : -1;
            root.value = Math.max(root.from, Math.min(root.to, root.value + Tokens.controlPageStepFactor * direction * root.stepSize));
            root.valueModified();
            event.accepted = true;
        }
    }

    // A hidden or disabled spin box never takes input, whoever gives it the focus: every key but Tab, Backtab and Escape is
    // swallowed (press and release), no assistive-technology increase. It hands the focus on (FocusGuard) and the edit in
    // progress commits as on any focus-out (AppKit: the field resigns first responder).
    FocusGuard {}

    Keys.onReleased: event => {
        if ((!root.visible || !root.enabled) && !ActivationKeys.propagates(event.key))
            event.accepted = true;
    }

    Accessible.onIncreaseAction: if (root.visible && root.enabled) {
        root.increase();
        root.valueModified();
    }
    Accessible.onDecreaseAction: if (root.visible && root.enabled) {
        root.decrease();
        root.valueModified();
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
        readOnly: !root.editable || !root.visible || !root.enabled  // also refuses the accessibility InsertText
        validator: root.validator
        inputMethodHints: Qt.ImhFormattedNumbersOnly
        opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1
        Accessible.role: Accessible.EditableText
        Accessible.name: root.accessibleName
        // Never takes input while hidden or disabled: every key but Tab, Backtab and Escape is swallowed, on press and on release.
        Keys.onPressed: event => {
            if ((!root.visible || !root.enabled) && !ActivationKeys.propagates(event.key))
                event.accepted = true;
        }
        Keys.onReleased: event => {
            if ((!root.visible || !root.enabled) && !ActivationKeys.propagates(event.key))
                event.accepted = true;
        }

        TextCursor {}
    }

    up.indicator: Item {
        x: root.width - width
        height: root.height / 2
        width: Tokens.controlStepperWidth + Tokens.spacingXs
        opacity: Appearance.dimsDisabled(root) || root.value >= root.to ? Tokens.materialDisabledOpacity : 1

        Rectangle {
            anchors.fill: parent
            anchors.margins: Tokens.controlStepperInset
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
        opacity: Appearance.dimsDisabled(root) || root.value <= root.from ? Tokens.materialDisabledOpacity : 1

        Rectangle {
            anchors.fill: parent
            anchors.margins: Tokens.controlStepperInset
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

    // The field of a TextField (UI audit 2026-11-05, LOW: a grey well here, a white field there): white with a fine border in
    // the light appearance, the translucent fill in the dark one.
    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity) : Appearance.colors.windowBackground
        border.width: Appearance.increaseContrast || !Appearance.dark ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        FocusRing {
            visible: root.activeFocus
        }
    }
}
