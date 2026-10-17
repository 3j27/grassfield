import QtQuick
import Grassfield.Ui

// Radio / mode row: round icon button (accent when on), title, state, optional chevron.
// The icon toggles; the text and the chevron expand the section. Keyboard: Space/Return toggle,
// Right expands, Left collapses.
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
    onArrow: direction => {
        if (expandable && available && (direction > 0) !== expanded)
            expandToggled();
    }

    Rectangle {
        id: circle
        width: Tokens.panelCcIconButton
        height: width
        radius: width / 2
        color: root.on ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }

        Icon {
            anchors.centerIn: parent
            size: Tokens.menuIconSize
            name: root.iconName
            color: root.on ? Appearance.colors.accentText : Appearance.colors.text
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.available
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggled()
        }
    }

    Item {
        anchors.left: circle.right
        anchors.leftMargin: Tokens.spacingSm
        anchors.right: parent.right
        height: parent.height

        Column {
            anchors.left: parent.left
            anchors.right: chevron.visible ? chevron.left : parent.right
            anchors.rightMargin: chevron.visible ? Tokens.spacingXs : 0
            anchors.verticalCenter: parent.verticalCenter

            Label {
                width: parent.width
                text: root.title
            }

            Caption {
                width: parent.width
                text: root.subtitle
                visible: text !== ""
            }
        }

        Icon {
            id: chevron
            visible: root.expandable
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.panelCcChevron
            name: root.expanded ? "chevron-down" : "chevron-right"
            color: Appearance.colors.textSecondary
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.expandable && root.available
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expandToggled()
        }
    }
}
