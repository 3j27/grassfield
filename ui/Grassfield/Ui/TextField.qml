import QtQuick
import QtQuick.Templates as T

// Single-line text field (QtQuick.Templates TextField): a rounded field (white with a fine border in the light appearance, as
// macOS; a translucent fill in the dark one), the I-beam pointer, the
// accent selection, the placeholder in the secondary colour, and the keyboard focus ring while it has the focus.
// Input method, selection, clipboard and accessibility (EditableText) are the template's.
T.TextField {
    id: root

    property string accessibleName: ""
    // The field's shape and fill; SearchField makes it a capsule with a light fill and no border.
    property real fieldRadius: Tokens.radiusControl
    property color fieldColor: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity) : Appearance.colors.windowBackground
    property bool fieldBorder: !Appearance.dark

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, contentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(Tokens.controlFieldHeight, implicitBackgroundHeight + topPadding + bottomPadding)
    leftPadding: Tokens.spacingSm
    rightPadding: Tokens.spacingSm
    verticalAlignment: TextInput.AlignVCenter
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    selectByMouse: true
    // The selection survives the global menu taking the keyboard (Edit > Cut/Copy act on it).
    persistentSelection: true
    color: Appearance.colors.text
    placeholderTextColor: Appearance.colors.textSecondary
    selectionColor: Appearance.highlight
    selectedTextColor: Appearance.highlightText
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyBodySize
    // Read-only while hidden or disabled: the accessibility text write (SetTextContents, InsertText) is refused with the keys. A
    // field that sets readOnly itself replaces this default (a read-only field is read-only whatever its state).
    readOnly: !root.visible || !root.enabled
    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    Accessible.role: Accessible.EditableText
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.placeholderText

    // A hidden or disabled field never takes input, whoever gives it the focus: every key but Tab, Backtab and Escape is
    // swallowed, on press and on release. (AppKit: such a field resigns first responder, and ending the edit commits it as
    // on any focus-out: FocusGuard hands the focus on.)
    Keys.onPressed: event => {
        if ((!root.visible || !root.enabled) && !ActivationKeys.propagates(event.key))
            event.accepted = true;
    }
    Keys.onReleased: event => {
        if ((!root.visible || !root.enabled) && !ActivationKeys.propagates(event.key))
            event.accepted = true;
    }

    TextCursor {}
    FocusGuard {}

    background: Rectangle {
        radius: root.fieldRadius
        color: root.fieldColor
        border.width: Appearance.increaseContrast || root.fieldBorder ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        FocusRing {
            shapeRadius: root.fieldRadius
            visible: root.activeFocus
        }
    }
}
