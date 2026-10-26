pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// The (…) button at the end of a list row (macOS 27 Wi-Fi networks): a ringed ellipsis in the secondary colour that opens a
// pull-down menu of the row's actions below it, its left edge on the button's. `items`: [{id, text, destructive?}] as
// PopupMenu takes them; choosing one emits chosen(id). Space, Return and a click open it; the menu keeps the keyboard.
Item {
    id: root

    property var items: []
    property string accessibleName: ""

    signal chosen(string id)

    implicitWidth: Tokens.settingsWifiMoreSize
    implicitHeight: Tokens.settingsWifiMoreSize
    activeFocusOnTab: true
    Accessible.role: Accessible.ButtonMenu
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: root.openMenu()

    function openMenu(): void {
        if (root.items.length > 0)
            popup.open();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openMenu();
            event.accepted = true;
        }
    }

    Icon {
        anchors.centerIn: parent
        name: "ellipsis-circle"
        size: Tokens.settingsWifiMoreSize
        color: mouse.pressed ? Appearance.colors.text : Appearance.windowSecondary
    }

    FocusRing {
        shapeRadius: root.width / 2
        visible: root.activeFocus
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        onClicked: {
            root.forceActiveFocus();
            root.openMenu();
        }
    }

    T.Popup {
        id: popup

        x: 0
        y: root.height + Tokens.spacingXs
        width: menu.width
        height: menu.height
        padding: 0
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside
        background: Item {}

        onAboutToShow: {
            menu.model = root.items;
            menu.measure();
            menu.currentIndex = 0;
        }
        onOpened: menu.forceActiveFocus()
        onClosed: {
            if (root.visible)
                root.forceActiveFocus();
        }

        // A Popup resizes its content item, which would replace the menu's own size bindings: the menu sits in a plain Item.
        contentItem: Item {
            implicitWidth: menu.width
            implicitHeight: menu.height

            PopupMenu {
                id: menu
                accessibleName: root.accessibleName
                onActivated: item => {
                    popup.close();
                    root.chosen(item.id);
                }
                onCloseRequested: popup.close()
            }
        }
    }
}
