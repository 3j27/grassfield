pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Paged grid of the Apps items. Only the current page and its neighbours (and the page a drag
// started on) have cells; pages slide, or crossfade under Reduce Motion.
Item {
    id: root

    required property var controller
    required property var host

    readonly property var g: controller.grid
    readonly property var placeholder: ({kind: "none", key: "", name: ""})

    width: g.gridW
    height: g.gridH

    Repeater {
        model: root.controller.pageCount

        Item {
            id: pg

            required property int index

            readonly property bool near: Math.abs(index - root.controller.page) <= 1 || index === root.host.dragPage
            readonly property bool current: index === root.controller.page

            width: root.width
            height: root.height
            x: Appearance.reduceMotion ? 0 : (index - root.controller.page) * root.host.width
            opacity: Appearance.reduceMotion ? (current ? 1 : 0) : 1
            visible: near && (current || !Appearance.reduceMotion || opacity > 0.01)

            Behavior on x {
                enabled: root.controller.open
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }
            }

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Repeater {
                model: pg.near ? Math.max(0, Math.min(root.g.perPage, root.controller.items.length - pg.index * root.g.perPage)) : 0

                AppsCell {
                    id: cell

                    required property int index

                    itemIndex: pg.index * root.g.perPage + index
                    info: root.controller.items[itemIndex] ?? root.placeholder
                    host: root.host
                    cellW: root.g.cellW
                    cellH: root.g.cellH
                    iconSize: root.g.icon
                    dragEnabled: !root.controller.searching
                    selected: root.controller.selected === itemIndex
                    x: (index % root.g.cols) * root.g.cellW
                    y: Math.floor(index / root.g.cols) * root.g.cellH
                    onActivated: root.controller.activate(info)
                }
            }
        }
    }
}
