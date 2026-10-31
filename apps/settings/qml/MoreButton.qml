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
    // The ring shows for the keyboard's focus only, as a control's visualFocus: a click focuses the button without it, and
    // the focus the menu hands back keeps the way the menu was opened.
    property bool clickFocused: false
    property bool clickOpened: false
    readonly property bool visualFocus: root.activeFocus && !root.clickFocused

    signal chosen(string id)

    implicitWidth: Tokens.settingsWifiMoreSize
    implicitHeight: Tokens.settingsWifiMoreSize
    activeFocusOnTab: true
    onActiveFocusChanged: if (!root.activeFocus)
        root.clickFocused = false
    Accessible.role: Accessible.ButtonMenu
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: root.openMenu(false)

    function openMenu(byClick: bool): void {
        root.clickOpened = byClick;
        if (root.items.length > 0)
            popup.open();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openMenu(false);
            event.accepted = true;
        }
    }

    // ToolButton's states behind the glyph: the hover fill under the pointer, the pressed fill while pressed (ADR-0039 step 15).
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Appearance.withAlpha(Appearance.colors.hover, mouse.pressed ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
        visible: mouse.pressed || mouse.containsMouse
    }

    Icon {
        anchors.centerIn: parent
        name: "ellipsis-circle"
        size: Tokens.settingsWifiMoreSize
        color: mouse.pressed ? Appearance.colors.text : Appearance.windowSecondary
    }

    FocusRing {
        shapeRadius: root.width / 2
        visible: root.visualFocus
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            root.clickFocused = true;
            root.forceActiveFocus();
            root.openMenu(true);
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
            if (root.visible) {
                root.clickFocused = root.clickOpened;
                root.forceActiveFocus();
            }
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
