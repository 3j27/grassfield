import QtQuick
import Grassfield.Ui

// Radio / mode row: round icon button (accent when on), title, state, optional chevron.
// The icon toggles; the text and the chevron expand the section. Keyboard: Space toggles (Return too, except on an
// expandable row where Return opens the section); Left/Right move to the capsule beside, and Right on the last
// capsule of a row opens the section.
NavItem {
    id: root

    property string iconName: ""
    property string title: ""
    property string subtitle: ""
    property bool on: false
    property bool expandable: false
    property bool expanded: false
    // False: the row is hidden (and so out of the Tab order): no hardware or service.
    property bool available: true
    // Left and right inset inside a 2x1 module (the row fills the whole capsule, so its focus ring does too).
    property real inset: 0
    // A 1x1 circle module (macOS: Stage Manager, Airplane Mode): the disk is the whole module, accent when on, plain glass when off,
    // with the glyph centred and no text.
    property bool circleModule: false

    signal toggled
    signal expandToggled

    width: parent ? parent.width : implicitWidth
    height: Tokens.panelCcIconButton
    checkable: true
    checked: on
    accessibleName: subtitle !== "" ? title + ", " + subtitle : title
    ringRadius: height / 2
    visible: available
    onActivated: if (available) toggled()
    // The chevron's action (open the section: the Wi-Fi networks, the sound devices) is an accessible action of its own:
    // increase opens the section, decrease closes it (A11Y-09).
    Accessible.onIncreaseAction: if (expandable && available && !expanded)
        expandToggled()
    Accessible.onDecreaseAction: if (expandable && available && expanded)
        expandToggled()
    handlesArrow: true
    returnActivates: !expandable
    onConfirmed: if (expandable && available) expandToggled()
    onArrow: direction => {
        if (!root.navigate(direction, 0) && expandable && available && direction > 0 && !expanded)
            expandToggled();
    }

    HoverHandler {
        id: hover
    }

    Rectangle {
        id: circle
        x: root.circleModule ? 0 : root.inset
        anchors.verticalCenter: parent.verticalCenter
        width: root.circleModule ? root.width : Tokens.panelCcIconButton
        height: width
        radius: width / 2
        color: root.on ? Appearance.colors.accent : (root.circleModule ? "transparent" : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity))

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }

        Icon {
            anchors.centerIn: parent
            size: Tokens.quicksettingsDiskGlyph
            name: root.iconName
            color: root.on ? Appearance.colors.accentText : Appearance.colors.text
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.available
            cursorShape: Qt.ArrowCursor
            onClicked: root.toggled()
        }
    }

    Item {
        visible: !root.circleModule
        anchors.left: circle.right
        anchors.leftMargin: Tokens.spacingSm
        anchors.right: parent.right
        anchors.rightMargin: root.inset > 0 ? Tokens.spacingXs : 0
        height: parent.height

        Column {
            anchors.left: parent.left
            // Text is elided before the chevron, never under it.
            anchors.right: parent.right
            anchors.rightMargin: chevron.visible ? chevron.width + Tokens.spacingXs : 0
            anchors.verticalCenter: parent.verticalCenter

            Label {
                width: parent.width
                text: root.title
                // The title is the emphasized line, the state is regular (macOS model).
                font.weight: Tokens.typographyMenuBoldWeight
                // Long module titles wrap to a second line inside the tile at the one size (GF-097, macOS: Control Center wraps and
                // never shrinks the type, audit 2026-10-25: "Do Not Disturb" and "Airplane Mode" shrank to 11 and wrapped to three
                // lines); a word wider than the capsule is elided.
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            Caption {
                width: parent.width
                text: root.subtitle
                visible: text !== ""
                // Fixed states wrap to two lines; only a device or network name that
                // is longer still ends in an ellipsis.
                wrapMode: Text.WordWrap
                maximumLineCount: 2
            }
        }

        // The chevron only shows while the row is hovered or focused (a 139-pt capsule has no room for it).
        Icon {
            id: chevron
            visible: root.expandable && (hover.hovered || root.activeFocus || root.expanded)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.panelCcChevron
            name: root.expanded ? "chevron-down" : "chevron-right"
            color: Appearance.colors.textSecondary
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.available
            cursorShape: Qt.ArrowCursor
            onClicked: root.expandable ? root.expandToggled() : root.toggled()
        }
    }
}
