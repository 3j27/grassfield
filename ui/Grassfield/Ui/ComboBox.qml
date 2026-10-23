pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Pop-up button (QtQuick.Templates ComboBox): the current choice on a rounded translucent button with a chevron; the list
// is a Grassfield PopupMenu in a Popup below the button (above it where the window has no room), the current row checked.
// model: [{id, text}]; value is the selected id (the host owns it: the control reports `picked(id)` and shows `value`
// again at once); Space, Return, Enter and the arrow keys open the list.
T.ComboBox {
    id: root

    property string value: ""
    property string accessibleName: ""
    readonly property bool open: root.popup.visible
    readonly property int valueIndex: {
        const m = root.model;
        for (let i = 0; m && i < m.length; i++) {
            if (m[i].id === root.value)
                return i;
        }
        return -1;
    }

    signal picked(string id)

    textRole: "text"
    valueRole: "id"
    currentIndex: root.valueIndex
    displayText: root.valueIndex >= 0 ? (root.model)[root.valueIndex].text : ""
    implicitWidth: Tokens.settingsPickerWidth
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.accessibleName
    Accessible.description: root.displayText
    Accessible.onPressAction: root.popup.open()

    onModelChanged: root.currentIndex = Qt.binding(() => root.valueIndex)

    // The template steps the selection with the arrows; here every opening key shows the list instead.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            if (root.enabled)
                root.popup.open();
            event.accepted = true;
        }
    }

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast ? 1 : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, root.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.enabled && (root.hovered || root.down)
        }

        FocusRing {
            visible: root.activeFocus
        }
    }

    contentItem: Text {
        textFormat: Text.PlainText
        leftPadding: Tokens.spacingMd
        rightPadding: Tokens.menuIconSize + Tokens.spacingSm + Tokens.spacingXs
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root.displayText
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    indicator: Icon {
        name: "chevron-down"
        size: Tokens.menuIconSize
        x: root.width - width - Tokens.spacingSm
        y: (root.height - height) / 2
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    }

    popup: T.Popup {
        id: popup

        y: root.height + Tokens.spacingXs
        x: root.width - width
        width: menu.width
        height: menu.height
        padding: 0
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside
        onAboutToShow: {
            const items = [];
            const m = root.model;
            for (let i = 0; m && i < m.length; i++)
                items.push({id: m[i].id, text: m[i].text, checked: i === root.valueIndex});
            menu.model = items;
            menu.currentIndex = Math.max(0, root.valueIndex);
        }
        onOpened: menu.forceActiveFocus()

        background: Item {}

        contentItem: PopupMenu {
            id: menu
            accessibleName: root.accessibleName
            onCloseRequested: popup.close()
            onActivated: item => {
                popup.close();
                root.forceActiveFocus();
                root.picked(item.id);
                // Back to what the host holds: it moves `value` if it accepts the choice.
                root.currentIndex = Qt.binding(() => root.valueIndex);
            }
        }
    }
}
