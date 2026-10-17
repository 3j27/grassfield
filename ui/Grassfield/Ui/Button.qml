import QtQuick

// Push button. primary = accent fill (default action), destructive tints the label.
Item {
    id: root

    property string text: ""
    property bool primary: false
    property bool destructive: false

    signal clicked

    readonly property bool hovered: mouse.containsMouse

    implicitWidth: Math.max(Tokens.controlButtonMinWidth, label.implicitWidth + 2 * Tokens.spacingLg)
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.focusable: true
    Accessible.onPressAction: root.clicked()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.clicked();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: root.primary ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: root.primary ? Appearance.colors.text : Appearance.colors.accent

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
            visible: root.hovered
        }
    }

    Text {
        textFormat: Text.PlainText
        id: label
        anchors.centerIn: parent
        width: Math.min(implicitWidth, root.width - 2 * Tokens.spacingSm)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        text: root.text
        color: root.primary ? Appearance.colors.accentText : (root.destructive ? Appearance.colors.danger : Appearance.colors.text)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.clicked();
        }
    }
}
