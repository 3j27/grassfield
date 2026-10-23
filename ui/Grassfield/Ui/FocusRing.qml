import QtQuick

// The one keyboard focus ring of every Grassfield control: Tokens.controlFocusOutline (3 px) outside the control's
// shape, in the focus ring colour (accent, or the text colour where the accent does not hold 3:1 against the material).
// Put it inside a control and show it with `visible: root.activeFocus` (text fields) or `root.visualFocus`; it fills the
// control and grows outwards, so the control's own geometry never changes. `shapeRadius` is the control's corner radius.
Rectangle {
    property real shapeRadius: Tokens.radiusControl

    anchors.fill: parent
    anchors.margins: -Tokens.controlFocusOutline
    radius: shapeRadius + Tokens.controlFocusOutline
    color: "transparent"
    border.width: Tokens.controlFocusOutline
    border.color: Appearance.focusRingColor
    opacity: Tokens.controlFocusOutlineOpacity
    // Not a target of the pointer: the control under it keeps every click.
    enabled: false
    Accessible.ignored: true
}
