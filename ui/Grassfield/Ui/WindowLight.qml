import QtQuick
import "WindowActions.js" as Actions

// One window light (WindowControls): the disc, its glyph, a focus ring for assistive technologies and the pointer entry.
// The pointer hit area is larger than the disc by window.lightHitSlop; the gaps between lights stay drag area.
Item {
    id: root

    // Position of the disc, set by WindowControls.
    required property real discX
    required property real discY
    required property color tint
    // "close", "minimize" or "plus" / "arrows" (WindowGlyph.kind).
    required property string glyph
    required property string accessibleName
    required property string accessibleDescription
    required property bool windowActive
    required property bool groupHovered
    property bool lightEnabled: true
    readonly property bool pressed: press.pressed

    // alt: Option/Alt was held at the click.
    signal activated(bool alt)

    readonly property bool grey: Actions.lightIsGrey(root.windowActive, root.groupHovered, root.lightEnabled)

    x: root.discX
    y: root.discY
    width: Tokens.windowLightDiameter
    height: Tokens.windowLightDiameter
    // Not in the Tab chain (macOS); focusable for assistive technologies, which then see the focus ring.
    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.description: root.accessibleDescription
    Accessible.focusable: true
    // An assistive technology's press acts like the pointer would: never on a hidden or disabled light (R12).
    Accessible.onPressAction: if (root.visible && root.lightEnabled)
        root.activated(false)

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.grey ? (Appearance.dark ? Tokens.windowInactiveLightDark : Tokens.windowInactiveLightLight) : root.tint
        border.width: 0 // the hairline is the ring below, over the fill

        // A pressed light darkens.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Qt.rgba(0, 0, 0, 1), Tokens.windowPressedOpacity)
            visible: press.pressed && root.lightEnabled
        }

        // The hairline darkens the light's own edge (the full 14 px disc stays: a translucent border on the disc itself is
        // drawn instead of its fill and showed what is behind the light, 12 px left; chrome.sh 4).
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: 1
            border.color: Appearance.withAlpha(Qt.rgba(0, 0, 0, 1), Tokens.windowLightBorderOpacity)
        }
    }

    // Keyboard focus ring (an assistive technology moved the focus here): outside the disc, accent.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Tokens.controlFocusOutline
        radius: width / 2
        color: "transparent"
        border.width: Tokens.controlFocusOutline
        border.color: Appearance.focusRingColor
        visible: root.activeFocus
    }

    WindowGlyph {
        anchors.centerIn: parent
        visible: Actions.glyphVisible(root.groupHovered, root.lightEnabled)
        kind: root.glyph
    }

    MouseArea {
        id: press
        anchors.fill: parent
        anchors.margins: -Tokens.windowLightHitSlop
        enabled: root.lightEnabled
        onClicked: mouse => root.activated((mouse.modifiers & Qt.AltModifier) !== 0)
    }
}
