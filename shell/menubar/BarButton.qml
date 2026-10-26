pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui
import qs.services

// Menu bar item, macOS model: it acts on the press (a menu opens on mouse down), the capsule shows only while it is
// pressed or its popup is open (no hover highlight in the bar), `entered` lets the bar switch menus on hover while one
// is open. Keyboard focusable.
Item {
    id: root

    property string accessibleName: ""
    property bool active: false
    // Opens one of the bar's menus: the bar switches to it on hover while another menu is open (macOS tracking).
    property bool opensMenu: false
    // The popup kind this item opens ("network", "volume", ...) for the keyboard cycle (Left/Right in an open menu, Ctrl+F8); empty: not in it.
    property string menuKind: ""
    // Padding on each side of the content (titles: menubar.itemPadding, status glyphs: menubar.statusItemPadding).
    property real padding: Tokens.menubarItemPadding
    // Padding on the left when it differs (the clock sits a status glyph's padding from the last glyph).
    property real leftPadding: root.padding
    // How far the capsule reaches past the item on each side (titles: menubar.highlightOutset, 14 around the text).
    property real highlightOutset: 0
    // Highlight colour (the bar passes the dark palette's while it has no background of its own).
    property color tint: Appearance.colors.hover
    // Soft shadow under the content (gate A2) while the bar is drawn straight on the wallpaper, in this colour.
    property bool shadowed: false
    property color shadowColor: Appearance.darkColors.shadow
    default property alias content: row.data
    readonly property bool hovered: hover.hovered

    signal activated
    signal entered
    signal scrolled(real delta)
    signal scrolledHorizontally(real delta)
    // A press with the right or middle button ("right" | "middle"); the left one is `activated`.
    signal auxPressed(string button)

    implicitWidth: row.implicitWidth + root.leftPadding + root.padding
    implicitHeight: Tokens.menubarHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: root.activated()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
            root.activated();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors {
            fill: parent
            topMargin: Tokens.menubarHoverInsetTop
            bottomMargin: Tokens.menubarHoverInsetBottom
            leftMargin: -root.highlightOutset
            rightMargin: -root.highlightOutset
        }
        radius: height / 2
        color: Appearance.withAlpha(root.tint, root.active ? Tokens.materialHoverOpacity * Tokens.materialHoverActiveFactor : Tokens.materialHoverOpacity)
        opacity: tap.pressed || root.active ? 1 : 0
        border.width: root.activeFocus ? Tokens.controlFocusOutline : 0
        border.color: Appearance.focusRingColor

        // The highlight appears at once with its menu and fades only when it goes (macOS, audit F6, C-23).
        Behavior on opacity {
            id: highlightFade

            NumberAnimation {
                duration: highlightFade.targetValue > 0 ? 0 : Appearance.duration(Tokens.motionFast)
            }
        }
    }

    // Focus ring stays visible even without hover.
    Rectangle {
        anchors {
            fill: parent
            topMargin: Tokens.menubarHoverInsetTop
            bottomMargin: Tokens.menubarHoverInsetBottom
            leftMargin: -root.highlightOutset
            rightMargin: -root.highlightOutset
        }
        radius: height / 2
        color: "transparent"
        visible: root.activeFocus
        border.width: Tokens.controlFocusOutline
        border.color: Appearance.focusRingColor
    }

    // Content with a faint soft shadow (gate A2) while the bar is drawn straight on the wallpaper: dark under light text, light
    // under dark text (the bar picks the colour from its adaptive tone). Off while a material is behind the bar.
    Item {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: (root.leftPadding - root.padding) / 2
        width: row.implicitWidth
        height: row.implicitHeight

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Tokens.spacingXs
            layer.enabled: root.shadowed
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: root.shadowColor
                shadowOpacity: Tokens.menubarTextShadowOpacity
                shadowBlur: Tokens.menubarTextShadowBlur
                shadowVerticalOffset: Tokens.menubarTextShadowOffsetY
            }
        }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.ArrowCursor
        onHoveredChanged: if (hovered)
            root.entered()
    }

    TapHandler {
        id: tap
        // No forceActiveFocus: the bar never has the keyboard (keyboard focus None), and a pointer press left the focus ring
        // drawn on the title until another item took the focus (macOS shows the ring only in keyboard navigation).
        // The menu this press opens must map while the button is known to be down (Popups.pointerHeld, cleared by the bar on the release).
        onPressedChanged: if (pressed) {
            Popups.pointerHeld = true;
            root.activated();
        }
    }

    // Right and middle presses (the left button is the TapHandler above).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.ArrowCursor
        onPressed: mouse => root.auxPressed(mouse.button === Qt.RightButton ? "right" : "middle")
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
            if (event.angleDelta.y !== 0)
                root.scrolled(event.angleDelta.y);
            if (event.angleDelta.x !== 0)
                root.scrolledHorizontally(event.angleDelta.x);
        }
    }
}
