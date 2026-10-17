pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter
import "Model.js" as Model

// Expanded Sound section (CC6): output devices (PipeWire sinks) and input devices (sources),
// the default one is checked; picking one makes it the default.
Column {
    id: root

    readonly property var outputs: Model.audioRows(Audio.sinks, Audio.sink, Audio.describe)
    readonly property var inputs: Model.audioRows(Audio.sources, Audio.source, Audio.describe)

    width: parent ? parent.width : implicitWidth
    spacing: Tokens.spacingXs

    Caption {
        text: qsTr("Output")
    }

    Caption {
        visible: root.outputs.length === 0
        text: qsTr("No output devices")
    }

    Repeater {
        model: root.outputs

        delegate: ListRow {
            required property var modelData

            width: root.width
            text: modelData.label
            selected: modelData.isDefault
            accessibleName: qsTr("Output: %1").arg(modelData.label)
            onActivated: Audio.select(modelData.node)
        }
    }

    Caption {
        text: qsTr("Input")
    }

    Caption {
        visible: root.inputs.length === 0
        text: qsTr("No input devices")
    }

    Repeater {
        model: root.inputs

        delegate: ListRow {
            required property var modelData

            width: root.width
            text: modelData.label
            selected: modelData.isDefault
            accessibleName: qsTr("Input: %1").arg(modelData.label)
            onActivated: Audio.selectSource(modelData.node)
        }
    }
}
