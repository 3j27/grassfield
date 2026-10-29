import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// A context menu of the window (as the Store's MenuPopup): Grassfield's PopupMenu in a popup of the window, closed by Esc or
// a click outside, the keyboard in the menu while it is open. `items`: [{id, text, enabled?, checked?, separator?}] as
// PopupMenu takes them; choosing one emits chosen(id). openAt(x, y): its top-left corner in its parent's coordinates. The
// focus goes back to `focusBack` when it closes.
T.Popup {
    id: root

    property var items: []
    property string accessibleName: ""
    property Item focusBack: null

    signal chosen(string id)

    function openAt(px: real, py: real): void {
        if (root.items.length === 0)
            return;
        root.x = px;
        root.y = py;
        root.open();
    }

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
        if (root.focusBack && root.focusBack.visible)
            root.focusBack.forceActiveFocus();
    }

    // A Popup resizes its content item, which would replace the menu's own size bindings: the menu sits in a plain Item.
    contentItem: Item {
        implicitWidth: menu.width
        implicitHeight: menu.height

        PopupMenu {
            id: menu
            accessibleName: root.accessibleName
            onActivated: item => {
                root.close();
                root.chosen(item.id);
            }
            onCloseRequested: root.close()
        }
    }
}
