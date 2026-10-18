pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Sound through PipeWire's `wpctl` (`wpctl status` is read; default device, volume and mute change only through
// SystemService, so never in a dev session).
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Sound")

    property bool answered: false
    property var audio: ({sinks: [], sources: []})

    readonly property var output: System.defaultOf(root.audio.sinks)
    readonly property var input: System.defaultOf(root.audio.sources)
    readonly property bool available: root.audio.sinks.length > 0 || root.audio.sources.length > 0

    function refresh(): void {
        root.system.query(System.QUERY.audio, "audio.status");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "audio.status") {
                root.answered = true;
                // A drag in progress keeps its own value; the next reading follows.
                if (!outVolume.busy && !inVolume.busy)
                    root.audio = ok ? System.parseAudio(output) : {sinks: [], sources: []};
            } else if (tag === "audio.act") {
                root.refresh();
            }
        }
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: root.refresh()

    SettingsGroup {
        visible: root.answered && !root.available
        footnote: qsTr("Sound is not available: PipeWire did not answer or no audio device was found.")
    }

    SettingsGroup {
        visible: root.audio.sinks.length > 0
        caption: qsTr("Output")

        Repeater {
            model: root.audio.sinks

            delegate: DeviceRow {
                id: sinkRow

                required property var modelData

                title: sinkRow.modelData.name
                leading: "volume-3"
                checked: sinkRow.modelData.isDefault
                onActivated: root.system.act("output device", System.setDefaultDevice(sinkRow.modelData.id), "audio.act")
            }
        }

        VolumeRow {
            id: outVolume
            system: root.system
            title: qsTr("Output volume")
            deviceId: root.output ? root.output.id : -1
            volume: root.output ? root.output.volume : 0
            muted: root.output ? root.output.muted : false
        }

        SettingsRow {
            title: qsTr("Mute")
            Toggle {
                accessibleName: qsTr("Mute output")
                enabled: root.output !== null
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                checked: root.output ? root.output.muted : false
                onToggled: c => root.system.act("mute", System.setMute(root.output ? root.output.id : -1, c), "audio.act")
            }
        }
    }

    SettingsGroup {
        visible: root.audio.sources.length > 0
        caption: qsTr("Input")

        Repeater {
            model: root.audio.sources

            delegate: DeviceRow {
                id: sourceRow

                required property var modelData

                title: sourceRow.modelData.name
                leading: "volume-1"
                checked: sourceRow.modelData.isDefault
                onActivated: root.system.act("input device", System.setDefaultDevice(sourceRow.modelData.id), "audio.act")
            }
        }

        VolumeRow {
            id: inVolume
            system: root.system
            title: qsTr("Input volume")
            deviceId: root.input ? root.input.id : -1
            volume: root.input ? root.input.volume : 0
            muted: root.input ? root.input.muted : false
        }

        SettingsRow {
            title: qsTr("Mute")
            Toggle {
                accessibleName: qsTr("Mute input")
                enabled: root.input !== null
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                checked: root.input ? root.input.muted : false
                onToggled: c => root.system.act("mute", System.setMute(root.input ? root.input.id : -1, c), "audio.act")
            }
        }
    }

    DevNote {
        system: root.system
    }
}
