pragma ComponentBehavior: Bound
import QtQuick
import "MenuNav.js" as MenuNav

// macOS-style menu on the frosted material. The host window supplies the blur region (see Material).
// model: [{id, text, shortcut?, iconName?, enabled?, checked?, destructive?, separator?, submenu?: [...]}]
// Keyboard: Up/Down/Home/End move, Return/Space activate, Right opens a submenu, Left closes it, Esc closes.
FocusScope {
    id: root

    property var model: []
    property int currentIndex: -1
    property bool isSubmenu: false
    property string accessibleName: ""
    // Index of the row whose submenu is open, -1 if none.
    property int openIndex: -1
    // Optional area that submenus stay inside (an app window's menu layer): a submenu that would cross its right edge
    // opens to the left of the menu, and one that would cross its bottom edge moves up. null: no limit.
    property Item bounds: null

    // A leaf item was chosen.
    signal activated(var item)
    // Esc on the top-level menu.
    signal closeRequested

    readonly property Item surface: material

    // Widest row; a Column sizes by width, not implicitWidth, so rows report through measure().
    property real rowsWidth: 0

    width: Math.max(Tokens.menuMinWidth, rowsWidth + 2 * Tokens.menuPadding)
    height: column.implicitHeight + 2 * Tokens.menuPadding
    activeFocusOnTab: true
    Accessible.role: Accessible.PopupMenu
    Accessible.name: root.accessibleName

    function measure(): void {
        let widest = 0;
        for (let i = 0; i < rows.count; i++) {
            const row = rows.itemAt(i);
            if (row)
                widest = Math.max(widest, row.implicitWidth);
        }
        rowsWidth = widest;
    }

    onModelChanged: Qt.callLater(measure)

    function closeSubmenu(): void {
        openIndex = -1;
        root.forceActiveFocus();
    }

    function openSubmenuAt(index: int, focusIt: bool): void {
        openIndex = index;
        if (focusIt)
            Qt.callLater(() => {
                if (submenuLoader.item)
                    (submenuLoader.item as Item).forceActiveFocus();
            });
    }

    function activateIndex(index: int): void {
        const item = root.model[index];
        if (!MenuNav.selectable(item))
            return;
        if (MenuNav.hasSubmenu(item))
            openSubmenuAt(index, true);
        else
            root.activated(item);
    }

    function keyName(key: int): string {
        switch (key) {
        case Qt.Key_Down:
            return "down";
        case Qt.Key_Up:
            return "up";
        case Qt.Key_Left:
            return "left";
        case Qt.Key_Right:
            return "right";
        case Qt.Key_Return:
        case Qt.Key_Enter:
            return "return";
        case Qt.Key_Space:
            return "space";
        case Qt.Key_Escape:
            return "escape";
        case Qt.Key_Home:
            return "home";
        case Qt.Key_End:
            return "end";
        }
        return "";
    }

    Keys.onPressed: event => {
        const name = root.keyName(event.key);
        if (name === "")
            return;
        event.accepted = true;
        const result = MenuNav.handleKey(root.model, root.currentIndex, name, root.isSubmenu);
        root.currentIndex = result.index;
        switch (result.action) {
        case "activate":
            root.activated(root.model[root.currentIndex]);
            break;
        case "openSubmenu":
            root.openSubmenuAt(root.currentIndex, true);
            break;
        case "close":
            root.closeRequested();
            break;
        case "closeSubmenu":
            // Handled by the parent menu through submenuLoader.
            root.closeRequested();
            break;
        }
    }

    Material {
        id: material
        anchors.fill: parent
        radius: Tokens.radiusMenu
    }

    Column {
        id: column
        x: Tokens.menuPadding
        y: Tokens.menuPadding
        width: root.width - 2 * Tokens.menuPadding

        Repeater {
            id: rows
            model: root.model
            onItemAdded: root.measure()

            delegate: Item {
                id: row

                required property var modelData
                required property int index

                width: column.width
                implicitWidth: loader.item ? (loader.item as Item).implicitWidth : 1
                onImplicitWidthChanged: root.measure()
                height: loader.item ? (loader.item as Item).implicitHeight : 0

                Loader {
                    id: loader
                    width: row.width
                    sourceComponent: row.modelData.separator ? separatorComponent : itemComponent
                }

                Component {
                    id: separatorComponent
                    MenuSeparator {}
                }

                Component {
                    id: itemComponent
                    MenuItem {
                        text: row.modelData.text !== undefined ? row.modelData.text : ""
                        shortcut: row.modelData.shortcut !== undefined ? row.modelData.shortcut : ""
                        iconName: row.modelData.iconName !== undefined ? row.modelData.iconName : ""
                        checked: row.modelData.checked === true
                        destructive: row.modelData.destructive === true
                        enabled: row.modelData.enabled !== false
                        hasSubmenu: MenuNav.hasSubmenu(row.modelData)
                        highlighted: root.currentIndex === row.index
                        onHovered: {
                            root.currentIndex = row.index;
                            if (hasSubmenu)
                                root.openSubmenuAt(row.index, false);
                            else if (root.openIndex !== -1)
                                root.openIndex = -1;
                        }
                        onClicked: root.activateIndex(row.index)
                    }
                }
            }
        }
    }

    // Submenu position: right of the menu, top aligned with its row; flipped and shifted to stay inside `bounds`.
    function submenuX(width: real): real {
        const right = root.width - Tokens.menuSubmenuOverlap;
        if (!root.bounds)
            return right;
        const margin = Tokens.spacingSm;
        const origin = root.mapToItem(root.bounds, 0, 0);
        if (origin.x + right + width <= root.bounds.width - margin)
            return right;
        const left = Tokens.menuSubmenuOverlap - width;
        // No room on either side: as far right as the area allows.
        return origin.x + left >= margin ? left : Math.max(margin - origin.x, root.bounds.width - margin - origin.x - width);
    }

    function submenuY(rowY: real, height: real): real {
        if (!root.bounds)
            return rowY;
        const margin = Tokens.spacingSm;
        const origin = root.mapToItem(root.bounds, 0, 0);
        return Math.max(margin - origin.y, Math.min(rowY, root.bounds.height - margin - origin.y - height));
    }

    // Submenu. A Loader by URL: a component cannot instantiate its own type directly.
    Loader {
        id: submenuLoader
        readonly property real rowY: {
            const r = rows.itemAt(root.openIndex);
            return r ? r.y : 0;
        }
        x: root.submenuX(submenuLoader.item ? (submenuLoader.item as Item).width : 0)
        y: root.submenuY(submenuLoader.rowY, submenuLoader.item ? (submenuLoader.item as Item).height : 0)
    }

    Connections {
        target: submenuLoader.item
        ignoreUnknownSignals: true

        function onActivated(item: var): void {
            root.activated(item);
        }

        function onCloseRequested(): void {
            root.closeSubmenu();
        }
    }

    onOpenIndexChanged: {
        const item = root.model[root.openIndex];
        if (root.openIndex >= 0 && MenuNav.hasSubmenu(item))
            submenuLoader.setSource("PopupMenu.qml", {model: item.submenu, isSubmenu: true, currentIndex: MenuNav.first(item.submenu), bounds: root.bounds});
        else
            submenuLoader.source = "";
    }
}
