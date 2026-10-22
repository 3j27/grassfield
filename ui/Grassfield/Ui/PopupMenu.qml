pragma ComponentBehavior: Bound
import QtQuick
import "MenuNav.js" as MenuNav

// macOS-style menu on the frosted material. The host window supplies the blur region (see Material).
// model: [{id, text, shortcut?, iconName?, enabled?, checked?, destructive?, separator?, submenu?: [...]}]
// A row may also be a swatch row (SwatchRow): {id, swatches: [{id, color, name, state}], caption?, enabled?, accessibleName?};
// choosing a swatch activates the swatch object itself (its own id).
// Keyboard: Up/Down/Home/End move, Return/Space activate, Right opens a submenu, Left closes it, Esc closes; on a
// swatch row Left/Right move between the swatches.
FocusScope {
    id: root

    property var model: []
    property int currentIndex: -1
    // The swatch under the keyboard cursor when the current row is a swatch row.
    property int swatchIndex: 0
    property bool isSubmenu: false
    // Whether Alt (Option) is down, live while the menu has the keyboard (a host shows its Option variants, macOS Dock menu).
    // A submenu does not accept the Alt events, so they reach the top-level menu through the item tree.
    property bool altHeld: false
    property string accessibleName: ""
    // Index of the row whose submenu is open, -1 if none.
    property int openIndex: -1
    // Optional area that submenus stay inside (an app window's menu layer): a submenu that would cross its right edge
    // opens to the left of the menu, and one that would cross its bottom edge moves up. null: no limit.
    property Item bounds: null
    // The open submenu (null when none): a host sized to its own window (a PopupWindow) grows to include it and gives
    // it a blur region of its own.
    readonly property Item submenuItem: submenuLoader.item as Item
    // Size of the menu together with its open submenus (no bounds: they open to the right and below), for that host.
    // Not childrenRect: reading it inside the host's binding re-enters the binding (binding loop on implicitWidth).
    readonly property size extent: {
        const sub = submenuLoader.item as PopupMenu;
        return Qt.size(Math.max(width, sub ? submenuLoader.x + sub.extent.width : 0), Math.max(height, sub ? submenuLoader.y + sub.extent.height : 0));
    }

    // A leaf item was chosen.
    signal activated(var item)
    // Esc on the top-level menu.
    signal closeRequested
    // Right on a row without a submenu (also inside a submenu) or Left in the top-level menu: the menu bar opens the
    // next (+1) or previous (-1) title's menu (macOS). Other hosts ignore it.
    signal menuStepRequested(int direction)

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
        else if (MenuNav.hasSwatches(item))
            root.activateSwatch(index, root.swatchIndex);
        else
            root.activated(item);
    }

    function activateSwatch(index: int, swatch: int): void {
        const item = root.model[index];
        if (MenuNav.selectable(item) && MenuNav.hasSwatches(item) && swatch >= 0 && swatch < item.swatches.length)
            root.activated(item.swatches[swatch]);
    }

    // Entering a row with the keyboard starts on its first swatch.
    onCurrentIndexChanged: root.swatchIndex = 0

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

    // The Alt key itself decides on its own press and release (whether a toolkit counts a modifier's own press in `modifiers`
    // varies); any other key reports the modifiers as they are.
    Keys.onReleased: event => {
        root.altHeld = event.key === Qt.Key_Alt ? false : (event.modifiers & Qt.AltModifier) !== 0;
    }

    Keys.onPressed: event => {
        root.altHeld = event.key === Qt.Key_Alt || (event.modifiers & Qt.AltModifier) !== 0;
        const name = root.keyName(event.key);
        if (name === "")
            return;
        event.accepted = true;
        const result = MenuNav.handleKey(root.model, root.currentIndex, name, root.isSubmenu);
        root.currentIndex = result.index;
        switch (result.action) {
        case "activate":
            if (MenuNav.hasSwatches(root.model[root.currentIndex]))
                root.activateSwatch(root.currentIndex, root.swatchIndex);
            else
                root.activated(root.model[root.currentIndex]);
            break;
        case "swatchPrevious":
            root.swatchIndex = MenuNav.stepSwatch(root.model[root.currentIndex], root.swatchIndex, -1);
            break;
        case "swatchNext":
            root.swatchIndex = MenuNav.stepSwatch(root.model[root.currentIndex], root.swatchIndex, 1);
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
        case "nextMenu":
            root.menuStepRequested(1);
            break;
        case "previousMenu":
            root.menuStepRequested(-1);
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
                    sourceComponent: row.modelData.separator ? separatorComponent : MenuNav.hasSwatches(row.modelData) ? swatchComponent : itemComponent
                }

                Component {
                    id: separatorComponent
                    MenuSeparator {}
                }

                Component {
                    id: swatchComponent
                    SwatchRow {
                        model: row.modelData.swatches
                        enabled: row.modelData.enabled !== false
                        caption: row.modelData.caption !== undefined ? row.modelData.caption : ""
                        accessibleName: row.modelData.accessibleName !== undefined ? row.modelData.accessibleName : ""
                        currentIndex: root.currentIndex === row.index ? root.swatchIndex : -1
                        onHoveredSwatch: swatch => {
                            if (root.openIndex !== -1)
                                root.openIndex = -1;
                            root.currentIndex = row.index;
                            root.swatchIndex = swatch;
                        }
                        onChosen: swatch => root.activateSwatch(row.index, swatch)
                    }
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

        function onMenuStepRequested(direction: int): void {
            root.menuStepRequested(direction);
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
