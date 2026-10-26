pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Displays.js" as Displays

// Displays > Arrange…: the displays as tiles in proportion to their logical size; drag one (or move a focused one with the arrow
// keys) and it snaps beside the nearest other along a whole edge (Displays.snapBeside). Done hands the new positions back
// (`arranged`), which the page tries as one change (ADR-0031).
Sheet {
    id: root

    property var monitors: []
    // name -> {x, y}: where each display is placed, in layout pixels.
    property var placed: ({})

    signal arranged(var positions)

    title: qsTr("Arrange Displays")
    message: qsTr("Drag a display to place it beside another.")
    confirmText: qsTr("Done")

    function openFor(list: var): void {
        root.monitors = list;
        const p = {};
        for (const m of list)
            p[m.name] = {x: m.x, y: m.y};
        root.placed = p;
        root.open();
    }

    // A monitor where it is placed.
    function at(m: var): var {
        const p = root.placed[m.name] ?? {x: m.x, y: m.y};
        return Object.assign({}, m, {x: p.x, y: p.y});
    }

    // Snap `m` dropped at (x, y) beside the nearest other display, and place it there.
    function drop(m: var, x: real, y: real): void {
        const size = Displays.logicalSize(m);
        let best = null, d = Infinity;
        for (const o of root.monitors) {
            if (o.name === m.name)
                continue;
            const oo = root.at(o), os = Displays.logicalSize(oo);
            const di = Math.hypot(x + size.w / 2 - oo.x - os.w / 2, y + size.h / 2 - oo.y - os.h / 2);
            if (di < d) {
                d = di;
                best = oo;
            }
        }
        const p = Object.assign({}, root.placed);
        p[m.name] = best ? Displays.snapBeside(m, x, y, best) : {x: Math.round(x), y: Math.round(y)};
        root.placed = p;
    }

    onAccepted: {
        const moved = [];
        for (const m of root.monitors) {
            const p = root.placed[m.name];
            if (p && (p.x !== m.x || p.y !== m.y))
                moved.push({name: m.name, x: p.x, y: p.y});
        }
        if (moved.length > 0)
            root.arranged(moved);
    }

    Item {
        id: area

        // The layout's bounds and the scale that fits them in the area, from the placed positions.
        readonly property var view: {
            let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
            for (const m of root.monitors) {
                const p = root.at(m), s = Displays.logicalSize(p);
                x0 = Math.min(x0, p.x);
                y0 = Math.min(y0, p.y);
                x1 = Math.max(x1, p.x + s.w);
                y1 = Math.max(y1, p.y + s.h);
            }
            if (!isFinite(x0))
                return {x: 0, y: 0, k: 1, ox: 0, oy: 0};
            const k = Math.min((area.width - 2 * Tokens.spacingLg) / (x1 - x0), (area.height - 2 * Tokens.spacingLg) / (y1 - y0));
            return {x: x0, y: y0, k: k, ox: (area.width - (x1 - x0) * k) / 2, oy: (area.height - (y1 - y0) * k) / 2};
        }

        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsDisplayPreviewHeight
        Accessible.role: Accessible.Grouping
        Accessible.name: qsTr("Display arrangement")

        Repeater {
            model: root.monitors

            delegate: Rectangle {
                id: tile

                required property var modelData
                readonly property var where: root.at(tile.modelData)
                readonly property var size: Displays.logicalSize(tile.where)
                // How far a drag has moved the tile, in the area's pixels.
                property real dragX: 0
                property real dragY: 0

                // The nearest other display, placed.
                function neighbour(): var {
                    let best = null, d = Infinity;
                    for (const o of root.monitors) {
                        if (o.name === tile.modelData.name)
                            continue;
                        const oo = root.at(o);
                        const di = Math.hypot(oo.x - tile.where.x, oo.y - tile.where.y);
                        if (di < d) {
                            d = di;
                            best = oo;
                        }
                    }
                    return best;
                }

                x: area.view.ox + (tile.where.x - area.view.x) * area.view.k + tile.dragX
                y: area.view.oy + (tile.where.y - area.view.y) * area.view.k + tile.dragY
                width: Math.max(Tokens.settingsDisplayMinSide, tile.size.w * area.view.k)
                height: Math.max(Tokens.settingsDisplayMinSide, tile.size.h * area.view.k)
                radius: Tokens.settingsDisplayRadius
                color: Appearance.withAlpha(Appearance.colors.accent, Tokens.materialFillOpacity)
                border.width: tile.activeFocus ? Tokens.controlFocusOutline : 1
                border.color: tile.activeFocus ? Appearance.focusRingColor : Appearance.colors.separator
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: Displays.isBuiltIn(tile.modelData) ? qsTr("Built-in Display") : (String(tile.modelData.model).trim() || tile.modelData.name)
                Accessible.description: qsTr("At %1, %2").arg(tile.where.x).arg(tile.where.y)

                // An arrow key puts the display on that side of the nearest other; with Shift it moves along its edge.
                Keys.onPressed: event => {
                    const o = tile.neighbour();
                    if (!o || [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) < 0)
                        return;
                    const os = Displays.logicalSize(o);
                    let x = tile.where.x, y = tile.where.y;
                    if (event.modifiers & Qt.ShiftModifier) {
                        const n = Tokens.settingsDisplayNudge;
                        x += event.key === Qt.Key_Left ? -n * tile.size.w : event.key === Qt.Key_Right ? n * tile.size.w : 0;
                        y += event.key === Qt.Key_Up ? -n * tile.size.h : event.key === Qt.Key_Down ? n * tile.size.h : 0;
                    } else if (event.key === Qt.Key_Left) {
                        x = o.x - 2 * tile.size.w;
                    } else if (event.key === Qt.Key_Right) {
                        x = o.x + os.w + tile.size.w;
                    } else if (event.key === Qt.Key_Up) {
                        y = o.y - 2 * tile.size.h;
                    } else {
                        y = o.y + os.h + tile.size.h;
                    }
                    root.drop(tile.modelData, x, y);
                    event.accepted = true;
                }

                // The menu bar along the top: every display has one in Grassfield.
                Rectangle {
                    x: 1
                    y: 1
                    width: parent.width - 2
                    height: Tokens.settingsDisplayMenuBarHeight
                    radius: Tokens.settingsDisplayRadius
                    color: Appearance.colors.text
                    opacity: Tokens.materialDisabledOpacity
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    width: parent.width - 2 * Tokens.spacingXs
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: tile.Accessible.name
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                MouseArea {
                    property point start

                    anchors.fill: parent
                    onPressed: mouse => {
                        tile.forceActiveFocus(Qt.MouseFocusReason);
                        start = mapToItem(area, mouse.x, mouse.y);
                    }
                    onPositionChanged: mouse => {
                        const p = mapToItem(area, mouse.x, mouse.y);
                        tile.dragX = p.x - start.x;
                        tile.dragY = p.y - start.y;
                    }
                    onReleased: {
                        const x = tile.where.x + tile.dragX / area.view.k;
                        const y = tile.where.y + tile.dragY / area.view.k;
                        tile.dragX = 0;
                        tile.dragY = 0;
                        root.drop(tile.modelData, x, y);
                    }
                }
            }
        }
    }
}
