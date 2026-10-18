import QtQuick
import Grassfield.Ui

// Window-wide layer that hosts a Grassfield PopupMenu (context menus, toolbar menus) and closes it
// on an outside click. open(model, x, y, handler, focusBack, keyboard): handler(id) runs for the chosen item.
Item {
    id: root

    property var handler: null
    property Item focusBack: null

    anchors.fill: parent
    visible: false
    z: 1000

    function firstSelectable(model: var): int {
        for (let i = 0; i < model.length; i++) {
            if (!model[i].separator && model[i].enabled !== false)
                return i;
        }
        return -1;
    }

    function open(model: var, x: real, y: real, handler: var, focusBack: Item, keyboard: bool): void {
        root.handler = handler;
        root.focusBack = focusBack;
        menu.model = model;
        menu.openIndex = -1;
        menu.currentIndex = keyboard ? root.firstSelectable(model) : -1;
        root.anchorX = x;
        root.anchorY = y;
        root.visible = true;
        root.place();
        menu.forceActiveFocus();
    }

    property real anchorX: 0
    property real anchorY: 0

    // At the pointer, flipped left/up when it would leave the window.
    function place(): void {
        const m = Tokens.spacingSm;
        let x = root.anchorX;
        let y = root.anchorY;
        if (x + menu.width > root.width - m)
            x = Math.max(m, x - menu.width);
        if (y + menu.height > root.height - m)
            y = Math.max(m, Math.min(root.height - menu.height - m, y - menu.height));
        menu.x = x;
        menu.y = y;
    }

    function close(): void {
        if (!root.visible)
            return;
        root.visible = false;
        menu.openIndex = -1;
        if (root.focusBack)
            root.focusBack.forceActiveFocus();
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: root.close()
    }

    PopupMenu {
        id: menu
        accessibleName: qsTr("Context menu")
        // Submenus (Open With, View As, Sort By) flip or move to stay inside the window.
        bounds: root
        onWidthChanged: if (root.visible) root.place()
        onHeightChanged: if (root.visible) root.place()
        onCloseRequested: root.close()
        onActivated: item => {
            const h = root.handler;
            root.close();
            if (h)
                h(item.id);
        }
    }
}
