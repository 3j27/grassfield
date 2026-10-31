pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.menubar
import qs.platform
import qs.services
import "TilingNav.js" as TilingNav
import "../platform/WindowTiling.js" as WindowTiling

// The tiling popover of a window's zoom light (docs/specs/tiling.md TL22-TL27, parity rows M19-M24): popup kind "tiling",
// opened by services/TilingHover from the plugin's tile-hover event, under the light. Its content is AppMenuModel's
// tilingPopover (the Window menu's rows and glyphs): the sections Move & Resize and Fill & Arrange as rows of glyphs, the
// Layouts section of the window's output class (TL27: a zone click places the window in that zone, and the suggestions
// follow), then Full Screen and Move to <display>; with Alt the alternates (M20), in full screen Exit Full Screen only (M21).
// Navigable with the arrows, Return and Esc (M24), a number picking a layout and a second number a zone (TL26); a click runs a
// glyph, a zone or a row. It closes on Esc, a click outside, an action, and, opened by the hover, once the pointer has been
// away from the light and the popover for tiling.hoverDelay (the overlay reports the pointer: pointerAt).
FocusScope {
    id: root

    readonly property string address: Popups.data.address !== undefined ? Popups.data.address : ""
    readonly property var toplevel: Compositor.toplevelByAddress(root.address)
    // The light in this output's coordinates (the overlay covers the output).
    readonly property var light: Popups.data.light !== undefined ? Popups.data.light : null
    readonly property bool hoverOpened: Popups.data.hover === true
    property bool altHeld: false
    readonly property bool fullscreen: root.toplevel ? root.toplevel.fullscreen : false
    readonly property bool inSplit: root.toplevel ? Compositor.inSplit(root.toplevel) : false

    readonly property var content: AppMenus.model.tilingPopover({
        alt: root.altHeld,
        tileable: Popups.data.tileable === true,
        canArrange: Compositor.canArrange,
        canLayouts: Compositor.canLayouts,
        canSplit: Compositor.canSplit,
        splitBlocked: Compositor.splitBlocked,
        splittable: Popups.data.splittable === true,
        outputClass: Compositor.outputClassOf(Popups.screenName),
        fullscreen: root.fullscreen,
        inSplit: root.inSplit,
        outputs: Compositor.otherOutputs(root.toplevel)
    })
    // The Layouts section in rows of this many layouts, as the glyph sections.
    readonly property int layoutColumns: 4
    // Every glyph, zone and row in reading order, for the keyboard (TilingNav). A delegate finds its entry by `key` (its model
    // data is a copy, never the same object). The zones of a row of layouts share a line, in the column of their layout.
    readonly property var entries: {
        const out = [];
        root.content.sections.forEach((section, s) => section.items.forEach((item, c) => out.push({key: "s" + s + ":" + c, line: "s" + s, column: c, enabled: item.enabled !== false, item: item})));
        root.content.layouts.forEach((layout, l) => layout.zones.forEach((zone, z) => out.push({
                        key: "l" + l + ":" + z,
                        line: "l" + Math.floor(l / root.layoutColumns),
                        column: l % root.layoutColumns + z / 10,
                        enabled: layout.enabled !== false,
                        item: {id: "zone", layout: layout.id, zone: z, enabled: layout.enabled !== false}
                    })));
        root.content.rows.forEach((item, r) => out.push({key: "r" + r, line: "r" + r, column: 0, enabled: item.enabled !== false, item: item}));
        return out;
    }
    property int current: -1
    readonly property string currentKey: root.current >= 0 && root.current < root.entries.length ? root.entries[root.current].key : ""
    // The layout a number key picked (TL26): its zones show their numbers until a second number picks one; -1 for none.
    property int pickedLayout: -1
    // The row whose submenu is open (Full Screen ›, docs/specs/tiling.md TL33), -1 for none: opened by the pointer on the row, a
    // click, Right or Return; Left or Esc in it closes it.
    property int subRow: -1
    readonly property var subModel: root.subRow >= 0 && root.subRow < root.content.rows.length ? (root.content.rows[root.subRow].submenu || []) : []
    // The open submenu, for the overlay's blur region (it lies outside the popover).
    readonly property Item submenuItem: root.subRow >= 0 ? subMenu : null

    width: Tokens.tilingPopoverWidth
    height: column.implicitHeight + 2 * Tokens.menuPadding
    activeFocusOnTab: true
    Accessible.role: Accessible.PopupMenu
    Accessible.name: qsTr("Window tiling")

    // Entering or leaving full screen or a Split View Desktop, or the window gone: what the popover offers no longer holds (TL22).
    // Judged against the state the popover opened in, once it settled, and closed after the binding round (integrator nested
    // pass of 1ee992e, BLOCKER A: closing from inside the first evaluation of `inSplit` re-entered `content`, `address` and the
    // overlay's Loader; the popover never showed and the overlay stayed mapped, swallowing input).
    // Each deferred step acts only while the popover is still the popup open (another popup may have taken its place).
    property var openedIn: null
    function settle(): void {
        if (Popups.kind !== "tiling")
            return;
        if (!root.toplevel) {
            Popups.close(); // the window is gone, or no window has that address: nothing to offer
            return;
        }
        root.openedIn = {address: root.address, fullscreen: root.fullscreen, inSplit: root.inSplit};
    }
    function closeIfOpen(): void {
        if (Popups.kind === "tiling")
            Popups.close();
    }
    function closeIfChanged(): void {
        const o = root.openedIn;
        if (o !== null && o.address === root.address && (o.fullscreen !== root.fullscreen || o.inSplit !== root.inSplit))
            Qt.callLater(root.closeIfOpen);
    }
    Component.onCompleted: Qt.callLater(root.settle)
    onAddressChanged: {
        root.openedIn = null; // another window's popover: its own state, once settled
        Qt.callLater(root.settle);
    }
    onFullscreenChanged: root.closeIfChanged()
    onInSplitChanged: root.closeIfChanged()
    onToplevelChanged: {
        if (!root.toplevel && root.openedIn !== null)
            Qt.callLater(root.closeIfOpen);
    }

    function indexOf(key: string): int {
        return root.entries.findIndex(e => e.key === key);
    }

    // Opens the submenu of row `r` beside it (on the right, or on the left when the output has no room); `byKey`: it takes the
    // keyboard on its first row.
    function openSub(r: int, byKey: bool): void {
        const rowItem = rowRepeater.itemAt(r);
        if (!rowItem)
            return;
        root.subRow = r;
        const right = root.mapToItem(null, root.width, 0).x;
        const room = root.Window.window ? root.Window.window.width - right : 0;
        subMenu.x = room >= subMenu.width + Tokens.spacingSm ? root.width - Tokens.menuSubmenuOverlap : Tokens.menuSubmenuOverlap - subMenu.width;
        subMenu.y = rowItem.mapToItem(root, 0, 0).y - Tokens.menuPadding;
        subMenu.currentIndex = byKey ? 0 : -1;
        if (byKey)
            subMenu.forceActiveFocus();
    }

    function closeSub(): void {
        root.subRow = -1;
        root.forceActiveFocus();
    }

    function run(item: var): void {
        if (!item || item.enabled === false)
            return;
        if (item.submenu) {
            root.openSub(root.content.rows.findIndex(r => r.id === item.id), true);
            return;
        }
        const window = root.toplevel;
        switch (item.id) {
        case "tile":
            Compositor.tile(window, item.place);
            break;
        case "arrange":
            Compositor.arrange(window, item.layout);
            break;
        case "fullscreen":
            Compositor.toggleFullscreen(window);
            break;
        case "split":
            Compositor.split(window, item.side);
            break;
        case "exitSplit":
            Compositor.unsplit(window);
            break;
        case "moveToOutput":
            Compositor.moveToOutput(window, item.output);
            break;
        case "zone":
            Compositor.placeInZone(window, item.layout, item.zone);
            break;
        }
        Popups.close();
    }

    // The zone of layout `layout` (index in the section) the keyboard or the pointer is on, -1 for none.
    function zoneOf(layout: int): int {
        const prefix = "l" + layout + ":";
        return root.currentKey.startsWith(prefix) ? Number(root.currentKey.slice(prefix.length)) : -1;
    }

    // The green light under (x, y), overlay coordinates: a click there is the light's (greenClick), not a click outside.
    function onLight(x: real, y: real): bool {
        return WindowTiling.inLight(root.light, x, y);
    }

    // A click on the green light while the popover is open (ADR-0036 D64, macOS: the button under its popover still works; the
    // overlay above it takes the click, the plugin never sees it): the light's own action (WindowTiling.greenAction), then the
    // popover closes. `alt`: Alt held at the click (the popover also follows Alt from its keys).
    function greenClick(alt: bool): void {
        const window = root.toplevel;
        if (!window) {
            Popups.close(); // the window went away (a null handle could match another window with no wayland handle)
            return;
        }
        switch (WindowTiling.greenAction(root.fullscreen, root.inSplit, root.altHeld || alt)) {
        case "unsplit":
            Compositor.unsplit(window);
            break;
        case "leaveFullscreen":
        case "enterFullscreen":
            Compositor.toggleFullscreen(window);
            break;
        case "toggleZoom":
            Compositor.toggleZoom(window);
            break;
        }
        Popups.close();
    }

    // The pointer anywhere on the output (overlay coordinates). Opened by the hover, the popover closes once the pointer has
    // stayed away from both the light and the popover for tiling.hoverDelay; it never closes for a pointer it has not seen.
    function pointerAt(x: real, y: real): void {
        if (!root.hoverOpened)
            return;
        const p = root.mapFromItem(null, x, y);
        const inLight = root.onLight(x, y);
        const s = subMenu.mapFromItem(null, x, y);
        const inSub = root.subRow >= 0 && subMenu.containsPoint(s.x, s.y);
        if (inLight || inSub || root.contains(p))
            away.stop();
        else if (!away.running)
            away.start();
    }

    Timer {
        id: away
        interval: Tokens.tilingHoverDelay
        onTriggered: Popups.close()
    }

    Keys.onReleased: event => {
        root.altHeld = event.key === Qt.Key_Alt ? false : (event.modifiers & Qt.AltModifier) !== 0;
    }

    Keys.onPressed: event => {
        root.altHeld = event.key === Qt.Key_Alt || (event.modifiers & Qt.AltModifier) !== 0;
        // TL26: a number picks a layout of the Layouts section, a second number a zone of it.
        const digit = root.content.layouts.length > 0 ? TilingNav.digitOf(event.key, event.nativeScanCode) : 0;
        if (digit > 0) {
            const pick = TilingNav.numberPick(root.content.layouts, root.pickedLayout, digit);
            if (pick.zone >= 0)
                root.run({id: "zone", layout: root.content.layouts[pick.picked].id, zone: pick.zone, enabled: true});
            else
                root.pickedLayout = pick.picked;
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Escape:
            // A picked layout lets go first (its numbers go away), the popover then.
            if (root.pickedLayout >= 0)
                root.pickedLayout = -1;
            else
                Popups.close();
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (root.current >= 0 && root.current < root.entries.length)
                root.run(root.entries[root.current].item);
            break;
        case Qt.Key_Right:
            // A row with a submenu (Full Screen ›) opens it, as a menu does; elsewhere Right moves along a glyph row.
            if (root.current >= 0 && root.current < root.entries.length && root.entries[root.current].item.submenu && root.entries[root.current].enabled) {
                root.run(root.entries[root.current].item);
                break;
            }
            // fallthrough
        case Qt.Key_Left:
        case Qt.Key_Up:
        case Qt.Key_Down:
        case Qt.Key_Home:
        case Qt.Key_End:
            root.current = TilingNav.step(root.entries, root.current, {
                [Qt.Key_Left]: "left",
                [Qt.Key_Right]: "right",
                [Qt.Key_Up]: "up",
                [Qt.Key_Down]: "down",
                [Qt.Key_Home]: "home",
                [Qt.Key_End]: "end"
            }[event.key]);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    Material {
        anchors.fill: parent
        glassClass: "menu"
        radius: Tokens.radiusMenu
    }

    Column {
        id: column
        x: Tokens.menuPadding
        y: Tokens.menuPadding
        width: root.width - 2 * Tokens.menuPadding

        Repeater {
            model: root.content.sections

            Column {
                id: section

                required property var modelData
                required property int index

                width: column.width

                MenuSeparator {
                    visible: section.index > 0
                    width: parent.width
                }

                Item {
                    width: parent.width
                    height: Tokens.menuItemHeight

                    Text {
                        textFormat: Text.PlainText
                        x: Tokens.menuItemPadding
                        anchors.verticalCenter: parent.verticalCenter
                        text: section.modelData.title
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyMenuSize
                        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                        font.weight: Tokens.typographyMenuBoldWeight
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter

                    Repeater {
                        model: section.modelData.items

                        Item {
                            id: glyphButton

                            required property var modelData
                            required property int index
                            readonly property string key: "s" + section.index + ":" + glyphButton.index
                            readonly property bool enabledHere: modelData.enabled !== false
                            readonly property bool highlighted: root.currentKey === glyphButton.key

                            width: Tokens.tilingGlyphPitch
                            height: Tokens.tilingGlyphRowHeight
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData.text
                            Accessible.description: modelData.shortcut !== undefined ? modelData.shortcut : ""
                            Accessible.onPressAction: if (glyphButton.enabledHere)
                                root.run(glyphButton.modelData)

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: Tokens.menuPadding
                                radius: Tokens.radiusMenu - Tokens.menuPadding
                                color: Appearance.withAlpha(Appearance.colors.text, Tokens.materialHoverOpacity)
                                visible: glyphButton.highlighted && glyphButton.enabledHere
                            }

                            TileGlyph {
                                anchors.centerIn: parent
                                zones: glyphButton.modelData.glyph ? glyphButton.modelData.glyph.zones : []
                                own: glyphButton.modelData.glyph ? glyphButton.modelData.glyph.own : 0
                                color: glyphButton.enabledHere ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: glyphButton.enabledHere
                                onEntered: root.current = root.indexOf(glyphButton.key)
                                onExited: if (glyphButton.highlighted)
                                    root.current = -1
                                onClicked: root.run(glyphButton.modelData)
                            }
                        }
                    }
                }
            }
        }

        // The Layouts section (TL27): the catalogue of the window's output class, miniature screens whose zones are targets.
        Column {
            visible: root.content.layouts.length > 0
            width: column.width

            MenuSeparator {
                width: parent.width
            }

            Item {
                width: parent.width
                height: Tokens.menuItemHeight

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Layouts")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                    font.weight: Tokens.typographyMenuBoldWeight
                }
            }

            Grid {
                anchors.horizontalCenter: parent.horizontalCenter
                columns: Math.max(1, Math.min(root.layoutColumns, root.content.layouts.length))

                Repeater {
                    model: root.content.layouts

                    Item {
                        id: layoutCell

                        required property var modelData
                        required property int index
                        readonly property bool enabledHere: modelData.enabled !== false
                        readonly property int zoneHere: root.zoneOf(layoutCell.index)

                        width: Tokens.tilingGlyphPitch
                        height: Tokens.tilingGlyphRowHeight
                        Accessible.role: Accessible.Grouping
                        Accessible.name: modelData.text

                        TileGlyph {
                            anchors.centerIn: parent
                            width: Tokens.tilingLayoutGlyphWidth
                            zones: layoutCell.modelData.zones
                            // At rest every zone is light; the zone under the pointer or the keyboard is drawn in full.
                            own: root.pickedLayout === layoutCell.index || layoutCell.zoneHere < 0 ? layoutCell.modelData.zones.length : layoutCell.zoneHere
                            numbered: root.pickedLayout === layoutCell.index
                            interactive: layoutCell.enabledHere
                            zoneNames: layoutCell.modelData.zones.map((z, i) => qsTr("%1, zone %2 of %3").arg(layoutCell.modelData.text).arg(i + 1).arg(layoutCell.modelData.zones.length))
                            color: layoutCell.enabledHere ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
                            onZoneHovered: zone => {
                                if (zone >= 0)
                                    root.current = root.indexOf("l" + layoutCell.index + ":" + zone);
                                else if (layoutCell.zoneHere >= 0)
                                    root.current = -1;
                            }
                            onZoneClicked: zone => root.run({id: "zone", layout: layoutCell.modelData.id, zone: zone, enabled: true})
                        }
                    }
                }
            }
        }

        MenuSeparator {
            visible: root.content.sections.length > 0
            width: parent.width
        }

        Repeater {
            id: rowRepeater
            model: root.content.rows

            Item {
                id: row

                required property var modelData
                required property int index
                readonly property string key: "r" + row.index
                readonly property bool enabledHere: modelData.enabled !== false
                readonly property bool highlighted: root.currentKey === row.key

                width: column.width
                height: Tokens.menuItemHeight
                Accessible.role: Accessible.MenuItem
                Accessible.name: modelData.text
                Accessible.onPressAction: if (row.enabledHere)
                    root.run(row.modelData)

                // The popover's rows take a neutral highlight (macOS), concentric with the popover.
                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.radiusMenu - Tokens.menuPadding
                    color: Appearance.withAlpha(Appearance.colors.text, Tokens.materialHoverOpacity)
                    visible: row.highlighted && row.enabledHere
                }

                TileGlyph {
                    visible: !!row.modelData.glyph
                    x: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    width: Tokens.menuIconSize
                    zones: row.modelData.glyph ? row.modelData.glyph.zones : []
                    own: row.modelData.glyph ? row.modelData.glyph.own : 0
                    color: rowLabel.color
                }

                Icon {
                    visible: row.modelData.iconName !== undefined
                    x: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: row.modelData.iconName !== undefined ? row.modelData.iconName : ""
                    color: rowLabel.color
                }

                Text {
                    id: rowLabel
                    textFormat: Text.PlainText
                    x: Tokens.menuItemPadding + Tokens.menuIconSize + Tokens.spacingSm
                    width: parent.width - x - Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    rightPadding: row.modelData.submenu ? Tokens.menuIconSize : 0
                    text: row.modelData.text
                    color: row.enabledHere ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                    font.weight: Tokens.typographySmallWeight
                }

                // A submenu's chevron (Full Screen ›).
                Icon {
                    visible: !!row.modelData.submenu
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: "chevron-right"
                    color: rowLabel.color
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: row.enabledHere
                    onEntered: {
                        root.current = root.indexOf(row.key);
                        if (row.modelData.submenu)
                            root.openSub(row.index, false);
                        else if (root.subRow >= 0)
                            root.closeSub();
                    }
                    onExited: if (row.highlighted && root.subRow !== row.index)
                        root.current = -1
                    onClicked: root.run(row.modelData)
                }
            }
        }
    }

    // Full Screen ›'s submenu (TL33): beside its row, the frosted menu of the menu bar's submenus (the overlay blurs it too).
    PopupMenu {
        id: subMenu
        visible: root.subRow >= 0
        isSubmenu: true
        model: root.subModel
        accessibleName: qsTr("Full Screen")
        onActivated: item => root.run(item)
        onCloseRequested: root.closeSub()
    }
}
