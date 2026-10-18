import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// Menu bar item: hover/pressed highlight (also while its popup is open), keyboard focusable.
Item {
    id: root

    property string accessibleName: ""
    property bool active: false
    // Padding on each side of the content (titles: menubar.itemPadding, status glyphs: menubar.statusItemPadding).
    property real padding: Tokens.menubarItemPadding
    // Highlight colour (the bar passes the dark palette's while it has no background of its own).
    property color tint: Appearance.colors.hover
    // Soft dark shadow under the content (gate A2) while the bar is drawn straight on the wallpaper.
    property bool shadowed: false
    default property alias content: row.data
    readonly property bool hovered: hover.hovered

    signal activated
    signal scrolled(real delta)

    implicitWidth: row.implicitWidth + 2 * root.padding
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
        }
        radius: height / 2
        color: Appearance.withAlpha(root.tint, root.active ? Tokens.materialHoverOpacity * Tokens.materialHoverActiveFactor : Tokens.materialHoverOpacity)
        opacity: root.hovered || root.active ? 1 : 0
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
    }

    // Focus ring stays visible even without hover.
    Rectangle {
        anchors {
            fill: parent
            topMargin: Tokens.menubarHoverInsetTop
            bottomMargin: Tokens.menubarHoverInsetBottom
        }
        radius: height / 2
        color: "transparent"
        visible: root.activeFocus
        border.width: Tokens.controlFocusRing
        border.color: Appearance.colors.accent
    }

    // Content with a soft drop shadow in three stacked passes (the row, its wrapper, the outer wrapper): each pass
    // casts the shadow of the previous result, so the halo gets denser without a harder edge (gate A2, as the
    // desktop labels). The passes are off while the bar has a material behind it.
    Item {
        id: pass3
        anchors.centerIn: parent
        width: row.implicitWidth
        height: row.implicitHeight
        layer.enabled: root.shadowed
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Appearance.darkColors.shadow
            shadowOpacity: Tokens.menubarTextShadowOpacity
            shadowBlur: Tokens.menubarTextShadowBlur
            shadowVerticalOffset: Tokens.menubarTextShadowOffsetY
        }

        Item {
            id: pass2
            anchors.fill: parent
            layer.enabled: root.shadowed
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Appearance.darkColors.shadow
                shadowOpacity: Tokens.menubarTextShadowOpacity
                shadowBlur: Tokens.menubarTextShadowBlur
                shadowVerticalOffset: Tokens.menubarTextShadowOffsetY
            }

            Row {
                id: row
                anchors.centerIn: parent
                spacing: Tokens.spacingXs
                layer.enabled: root.shadowed
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: Appearance.darkColors.shadow
                    shadowOpacity: Tokens.menubarTextShadowOpacity
                    shadowBlur: Tokens.menubarTextShadowBlur
                    shadowVerticalOffset: Tokens.menubarTextShadowOffsetY
                }
            }
        }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.ArrowCursor
    }

    TapHandler {
        onTapped: {
            root.forceActiveFocus();
            root.activated();
        }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => root.scrolled(event.angleDelta.y)
    }
}
