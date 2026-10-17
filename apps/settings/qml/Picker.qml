pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Drop-down choice. model: [{id, text}]; value is the selected id; picked(id) on user change.
// The list is a Grassfield PopupMenu drawn above the page (opaque: app windows never use blur).
Item {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""
    readonly property bool open: layer.visible

    signal picked(string id)

    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }
    readonly property string currentText: root.currentIndex >= 0 ? root.model[root.currentIndex].text : ""

    implicitWidth: Tokens.settingsPickerWidth
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    activeFocusOnTab: true
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.accessibleName
    Accessible.description: root.currentText
    Accessible.focusable: true
    Accessible.onPressAction: root.show()

    function show(): void {
        const items = [];
        for (let i = 0; i < root.model.length; i++)
            items.push({id: root.model[i].id, text: root.model[i].text, checked: i === root.currentIndex});
        menu.model = items;
        menu.currentIndex = Math.max(0, root.currentIndex);
        layer.visible = true;
        root.place();
        menu.forceActiveFocus();
    }

    // Below the picker, flipped above it when that would run past the window bottom, always inside the window.
    // Called again whenever the menu's size changes, so the position never uses a stale height.
    function place(): void {
        const below = root.mapToItem(layer, 0, root.height + Tokens.spacingXs);
        const above = root.mapToItem(layer, 0, -Tokens.spacingXs - menu.height);
        const maxY = layer.height - menu.height - Tokens.spacingSm;
        const y = below.y > maxY && above.y >= Tokens.spacingSm ? above.y : below.y;
        menu.x = Math.max(Tokens.spacingSm, Math.min(layer.width - menu.width - Tokens.spacingSm, below.x + root.width - menu.width));
        menu.y = Math.max(Tokens.spacingSm, Math.min(maxY, y));
    }

    function hide(): void {
        layer.visible = false;
        root.forceActiveFocus();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
            root.show();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
            visible: mouse.containsMouse
        }
    }

    Text {
        textFormat: Text.PlainText
        anchors {
            left: parent.left
            leftMargin: Tokens.spacingMd
            right: chevron.left
            rightMargin: Tokens.spacingXs
            verticalCenter: parent.verticalCenter
        }
        text: root.currentText
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    Icon {
        id: chevron
        name: "chevron-down"
        size: Tokens.menuIconSize
        anchors {
            right: parent.right
            rightMargin: Tokens.spacingSm
            verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.show();
        }
    }

    // Window-sized layer above the page: catches outside clicks and hosts the menu.
    Item {
        id: layer
        parent: root.Window.contentItem
        anchors.fill: parent
        visible: false
        z: 1000

        MouseArea {
            anchors.fill: parent
            onClicked: root.hide()
        }

        PopupMenu {
            id: menu
            accessibleName: root.accessibleName
            onHeightChanged: if (layer.visible) root.place()
            onWidthChanged: if (layer.visible) root.place()
            onCloseRequested: root.hide()
            onActivated: item => {
                root.hide();
                root.picked(item.id);
            }
        }
    }
}
