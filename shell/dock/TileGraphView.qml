pragma ComponentBehavior: Bound

import QtQuick
import Grassfield.Ui
import "TileGraph.js" as Logic

// Activity Monitor's live graph over its Dock tile (ADR-0038 f; docs/specs/activity.md AM62; View > Dock Icon in the app):
// network and disk as two series mirrored around the middle (in or read above, out or written below), CPU history as
// System and User stacked, CPU usage a gauge of ten segments. On a dark plate in both appearances, with the dark palette's
// graph colours; tokens only. The newest sample is at the right edge, one slot per sample of the file's thirty-two.
Item {
    id: root

    // {kind, samples} (TileGraph.parse), or null: nothing is drawn and the icon shows.
    property var graph: null
    property real radius: 0

    readonly property string kind: root.graph ? root.graph.kind : ""
    readonly property var samples: root.graph ? root.graph.samples : []
    readonly property real inset: Tokens.dockTileGraphInset
    readonly property real plotWidth: Math.max(0, root.width - 2 * root.inset)
    readonly property real plotHeight: Math.max(0, root.height - 2 * root.inset)
    readonly property real slot: root.plotWidth / Logic.MAX_SAMPLES
    readonly property real bar: Math.max(1, root.slot - Tokens.dockTileGraphGap)
    readonly property int lit: root.kind === "cpu-usage" && root.samples.length > 0
        ? Logic.litSegments(root.samples[root.samples.length - 1], Tokens.dockTileGraphSegments) : 0

    visible: root.graph !== null
    Accessible.role: Accessible.Graphic
    Accessible.name: root.kind === "cpu-usage" ? qsTr("CPU usage") : root.kind === "cpu-history" ? qsTr("CPU history")
        : root.kind === "disk" ? qsTr("Disk activity") : qsTr("Network usage")

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.dockTileGraphFillOpacity)
    }

    Column {
        visible: root.kind === "cpu-usage"
        x: root.inset
        y: root.inset
        width: root.plotWidth
        spacing: Tokens.dockTileGraphGap

        Repeater {
            model: root.kind === "cpu-usage" ? Tokens.dockTileGraphSegments : 0

            Rectangle {
                id: segment
                required property int index
                width: root.plotWidth
                height: Math.max(1, (root.plotHeight - (Tokens.dockTileGraphSegments - 1) * Tokens.dockTileGraphGap) / Tokens.dockTileGraphSegments)
                // The top segment first: lit from the bottom up.
                color: Tokens.dockTileGraphSegments - segment.index <= root.lit ? Tokens.colorDark.activityGraphUser
                    : Appearance.withAlpha(Appearance.colors.knob, Tokens.dockTileGraphUnlitOpacity)
            }
        }
    }

    Repeater {
        model: root.kind === "cpu-usage" ? 0 : root.samples.length

        Item {
            id: column
            required property int index
            readonly property var sample: root.samples[column.index]
            readonly property bool stacked: root.kind === "cpu-history"
            x: root.inset + root.plotWidth - (root.samples.length - column.index) * root.slot
            y: root.inset
            width: root.bar
            height: root.plotHeight

            // CPU history: System from the bottom, User on it. Network and disk: the first series up from the middle.
            Rectangle {
                id: first
                width: column.width
                height: column.stacked ? column.sample[0] * root.plotHeight : column.sample[0] * root.plotHeight / 2
                y: column.stacked ? root.plotHeight - first.height : root.plotHeight / 2 - first.height
                color: column.stacked ? Tokens.colorDark.activityGraphSystem : Tokens.colorDark.activityGraphIn
            }
            // CPU history: User above System. Network and disk: the second series down from the middle.
            Rectangle {
                id: second
                width: column.width
                height: column.stacked ? column.sample[1] * root.plotHeight : column.sample[1] * root.plotHeight / 2
                y: column.stacked ? root.plotHeight - column.sample[0] * root.plotHeight - second.height : root.plotHeight / 2
                color: column.stacked ? Tokens.colorDark.activityGraphUser : Tokens.colorDark.activityGraphOut
            }
        }
    }
}
