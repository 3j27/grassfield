import QtQuick
import QtQuick.Templates as T

// Single-line text field (QtQuick.Templates TextField): a translucent 22 px rounded field, the I-beam pointer, the
// accent selection, the placeholder in the secondary colour, and the keyboard focus ring while it has the focus.
// Input method, selection, clipboard and accessibility (EditableText) are the template's.
T.TextField {
    id: root

    property string accessibleName: ""

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
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        FocusRing {
            visible: root.activeFocus
        }
    }
}
