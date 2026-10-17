pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui

// Paged grid of the Apps items: one persistent cell per item; only the current page, its
// neighbours and the page a drag started on are shown. Pages slide, or crossfade under Reduce Motion.
Item {
    id: root

    required property var controller
    required property var host

    readonly property var g: controller.grid
    readonly property var placeholder: ({kind: "none", key: "", name: ""})

    width: g.gridW
    height: g.gridH

    // One cell per display item, kept across searches and layout edits (ScriptModel matches by key):
    // a cell only moves to its slot, or hides when its item is not shown, so filtering never
    // rebuilds or rebinds cells. Pages slide by moving `pager`.
    Item {
        id: pager

        x: Appearance.reduceMotion ? 0 : -root.controller.page * root.host.width

        Behavior on x {
            enabled: root.controller.open
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        Repeater {
            model: ScriptModel {
                values: root.controller.allItems
                objectProp: "key"
            }

            AppsCell {
                id: cell

                required property var modelData

                readonly property int slot: modelData.state.slot
                // Few derived properties: a keystroke re-evaluates them for every cell whose slot changes.
                readonly property int pageIndex: Math.floor(slot / root.g.perPage)

                itemIndex: slot
                info: root.controller.itemByKey[modelData.key] ?? root.placeholder
                host: root.host
                cellW: root.g.cellW
                cellH: root.g.cellH
                iconSize: root.g.icon
                dragEnabled: !root.controller.searching
                selected: modelData.state.selected
                shown: slot >= 0 && (pageIndex === root.controller.page || !Appearance.reduceMotion || opacity > 0.01)
                opacity: Appearance.reduceMotion ? (pageIndex === root.controller.page ? 1 : 0) : 1
                x: (Appearance.reduceMotion ? 0 : pageIndex * root.host.width) + (slot % root.g.perPage % root.g.cols) * root.g.cellW
                y: Math.floor(slot % root.g.perPage / root.g.cols) * root.g.cellH
                onActivated: root.controller.activate(info)

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                    }
                }
            }
        }
    }
}
