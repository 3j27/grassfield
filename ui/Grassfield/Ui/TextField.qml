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
    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    Accessible.role: Accessible.EditableText
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.placeholderText

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
