import QtQuick

// Push button. primary = accent fill (default action), destructive tints the label.
Item {
    id: root

    property string text: ""
    property bool primary: false
    property bool destructive: false
    // Alert style: a capsule, alertButtonHeight tall (a Dialog sets it on its buttons).
    property bool capsule: false
    // macOS push button: buttonHeight (24) tall instead of the roomier default (a sheet sets it on its buttons).
    property bool push: false

    signal clicked

    readonly property bool hovered: mouse.containsMouse

    implicitWidth: Math.max(Tokens.controlButtonMinWidth, label.implicitWidth + 2 * Tokens.spacingLg)
    implicitHeight: root.capsule ? Tokens.controlAlertButtonHeight : (root.push ? Tokens.controlButtonHeight : Tokens.menuItemHeight + Tokens.spacingSm)
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.focusable: true
    // An assistive technology's press (AT-SPI "press" action) goes through the same guard as the keys and the pointer.
    Accessible.onPressAction: root.activate()

    // The Button's only way to act, for every activation path (keys, accessibility press, pointer): a hidden or disabled
    // Button never acts, whatever asks or still holds the focus (R12: the polkit sheet's Allow). Returns whether it acted.
    function activate(): bool {
        if (!root.visible || !root.enabled)
            return false;
        root.clicked();
        return true;
    }

    Keys.onPressed: event => {
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
            return;
        // A hidden or disabled button never acts (activate()); its activation keys are swallowed all the same (they would
        // otherwise bubble up to a parent that acts on them). Every other key (Escape above all) propagates.
        root.activate();
        event.accepted = true;
    }

    Rectangle {
        anchors.fill: parent
        radius: root.capsule ? height / 2 : Tokens.radiusControl
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
        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
        font.weight: Tokens.typographyMenuWeight
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.ArrowCursor
        onClicked: {
            root.forceActiveFocus();
            root.activate();
        }
    }
}
