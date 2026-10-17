pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.widgets
import "../widgets/Placements.js" as Placements

// Desktop widgets (docs/specs/widgets.md): the widgets placed on the desktop of each screen, on a
// layer above the wallpaper and below windows (namespace grassfield-widgets, no exclusive zone).
// The input mask is exactly the widget rectangles (plus the whole window while a context menu
// is open, to catch the click that dismisses it), so clicks between widgets reach the layers below.
// Drag moves a widget; on release it snaps to the grid (nearest free cell) and is saved. While a
// window has focus on a screen its widgets are desaturated and dimmed; clicking a widget makes the
// desktop the active surface again until the focus changes.
Variants {
    model: Quickshell.screens

    Scope {
        id: scope

        required property ShellScreen modelData

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            readonly property ShellScreen modelData: scope.modelData

            readonly property var grid: Widgets.gridFor(modelData)
            readonly property real pitch: grid.cell + grid.gap
            readonly property var mine: Widgets.desktop.filter(e => e.screen === modelData.name)
            readonly property bool windowFocused: Compositor.focusedToplevel !== null && Compositor.focusedScreenName === modelData.name
            property bool desktopActive: false
            readonly property bool dimmed: windowFocused && !desktopActive
            property real dimAmount: dimmed ? 1 : 0

            // Drag in progress: uid of the widget and its offset from the cell.
            property string dragUid: ""
            property point dragOffset: Qt.point(0, 0)
            // Context menu.
            property var menuEntry: null
            property point menuAt: Qt.point(0, 0)

            function rectOf(entry: var): rect {
                const size = Placements.px(entry.size, grid.cell, grid.gap);
                const dragged = entry.uid === dragUid;
                return Qt.rect(grid.x0 + entry.col * pitch + (dragged ? dragOffset.x : 0), grid.y0 + entry.row * pitch + (dragged ? dragOffset.y : 0), size.w, size.h);
            }

            function commitDrag(entry: var): void {
                const r = rectOf(entry);
                const spot = Placements.snap(r.x - grid.x0, r.y - grid.y0, entry.size, grid.cell, grid.gap, grid.cols, grid.rows);
                dragUid = "";
                dragOffset = Qt.point(0, 0);
                Widgets.moveDesktop(entry.uid, spot.col, spot.row, modelData.name);
            }

            // A click on a widget keeps the desktop active (full color) for a while, as long as the
            // pointer stays over a widget; a window that is already focused sends no event to end it.
            function keepActive(): void {
                desktopActive = true;
                activeTimer.restart();
            }

            function closeMenu(): void {
                menuEntry = null;
            }

            function applyMenu(action: string): void {
                const entry = menuEntry;
                menuEntry = null;
                if (!entry)
                    return;
                if (action === "remove")
                    Widgets.remove(entry.uid);
                else if (action.startsWith("size:"))
                    Widgets.setSize(entry.uid, action.substring(5));
            }

            screen: modelData
            visible: mine.length > 0
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Bottom
            // Never takes the keyboard: focus stays with the user's window.
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-widgets"
            // qmllint disable missing-type
            mask: Region {
                regions: maskRects.instances
            }
            // qmllint enable missing-type

            Behavior on dimAmount {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.widgetDimMs)
                }
            }

            // One mask rectangle per widget, following drags.
            Variants {
                id: maskRects
                model: win.mine

                // qmllint disable missing-type
                delegate: Region {
                    // qmllint enable missing-type
                    required property var modelData
                    readonly property rect r: win.rectOf(modelData)

                    x: r.x
                    y: r.y
                    width: r.width
                    height: r.height
                }
            }

            Timer {
                id: activeTimer
                interval: Tokens.widgetActiveMs
                onTriggered: win.desktopActive = false
            }

            Connections {
                target: Compositor

                function onFocusedToplevelChanged(): void {
                    win.desktopActive = false;
                }
            }

            Item {
                id: tiles
                anchors.fill: parent
                layer.enabled: win.dimAmount > 0
                layer.effect: MultiEffect {
                    saturation: Tokens.widgetDimSaturation * win.dimAmount
                    brightness: Tokens.widgetDimBrightness * win.dimAmount
                }

                Repeater {
                    model: ScriptModel {
                        values: win.mine
                        objectProp: "uid"
                    }

                    delegate: WidgetHost {
                        id: tile

                        required property var modelData

                        entry: modelData
                        cell: win.grid.cell
                        gap: win.grid.gap
                        x: win.rectOf(modelData).x
                        y: win.rectOf(modelData).y
                        z: modelData.uid === win.dragUid ? 1 : 0
                        scale: modelData.uid === win.dragUid ? 1.03 : 1
                        onPressed: win.keepActive()
                        onMenuRequested: (px, py) => {
                            const p = tile.mapToItem(null, px, py);
                            win.menuAt = Qt.point(p.x, p.y);
                            win.menuEntry = modelData;
                        }
                        onHoveredChanged: if (hovered && win.desktopActive)
                            win.keepActive()
                        onRemoveRequested: Widgets.remove(modelData.uid)

                        Behavior on scale {
                            NumberAnimation {
                                duration: Appearance.duration(Tokens.motionFast)
                            }
                        }

                        DragHandler {
                            id: drag
                            target: null
                            acceptedButtons: Qt.LeftButton
                            cursorShape: active ? Qt.ClosedHandCursor : Qt.ArrowCursor
                            onActiveChanged: {
                                if (active)
                                    win.dragUid = tile.modelData.uid;
                                else if (win.dragUid === tile.modelData.uid)
                                    win.commitDrag(tile.modelData);
                            }
                            onActiveTranslationChanged: {
                                if (active)
                                    win.dragOffset = Qt.point(activeTranslation.x, activeTranslation.y);
                            }
                        }
                    }
                }
            }
        }

        // Context menu: an Overlay window that takes the keyboard while it is open (a Bottom layer
        // cannot), so arrows, Return and Esc work; clicking anywhere else dismisses it.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: menuWin

            screen: scope.modelData
            visible: win.menuEntry !== null
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-widgets-menu"

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: win.closeMenu()
            }

            Loader {
                active: win.menuEntry !== null
                x: Math.max(Tokens.spacingSm, Math.min(win.menuAt.x, menuWin.width - width - Tokens.spacingSm))
                y: Math.max(Tokens.spacingSm, Math.min(win.menuAt.y, menuWin.height - height - Tokens.spacingSm))
                sourceComponent: WidgetMenu {
                    entry: win.menuEntry
                    onChoose: action => win.applyMenu(action)
                    onCloseRequested: win.closeMenu()
                    Component.onCompleted: forceActiveFocus()
                }
            }
        }
    }
}
