pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Sound as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Sound): Output & Input, an Output / Input
// segmented control over the device table (Name, Type; the default device selected, a click or the arrow keys choose another),
// then the volume of that side (LevelRow) and Mute. PipeWire through `wpctl`: `wpctl status` is read, then `wpctl status -n` once a device
// is new (its node name gives the Type); default device, volume and mute change only through SystemService, so never in a dev
// session. No Sound Effects group: Grassfield plays no alert, start-up or interface sounds.
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Sound")

    property bool answered: false
    property var audio: ({sinks: [], sources: []})
    // PipeWire node id -> System.audioKind, from `wpctl status -n`.
    property var kinds: ({})
    // The ids the last `wpctl status -n` was asked for: a device whose kind it did not give is not asked about again.
    property var asked: ({})
    property bool naming: false
    // "output" or "input": the segmented control.
    property string side: "output"
    // The device being made the default, until the next reading.
    property int pending: -1

    readonly property var output: System.defaultOf(root.audio.sinks)
    readonly property var input: System.defaultOf(root.audio.sources)
    readonly property var current: root.side === "output" ? root.output : root.input
    readonly property bool available: root.audio.sinks.length > 0 || root.audio.sources.length > 0

    // The device rows, keyed by node id: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: sinkModel
    }

    ListModel {
        id: sourceModel
    }

    function syncRows(): void {
        const rows = list => list.map(d => ({nodeId: d.id, name: d.name, kind: root.kinds[d.id] ?? "", isDefault: d.isDefault}));
        System.syncModel(sinkModel, rows(root.audio.sinks), "nodeId");
        System.syncModel(sourceModel, rows(root.audio.sources), "nodeId");
    }

    onAudioChanged: {
        root.syncRows();
        const ids = root.audio.sinks.concat(root.audio.sources).map(d => d.id);
        if (!root.naming && ids.some(id => root.kinds[id] === undefined && root.asked[id] === undefined)) {
            const asked = {};
            for (const id of ids)
                asked[id] = true;
            root.asked = asked;
            root.naming = true;
            root.system.query(System.QUERY.audioNames, "audio.names");
        }
    }

    onKindsChanged: root.syncRows()
    // A device being chosen belongs to the other side's table.
    onSideChanged: root.pending = -1

    function kindLabel(kind: string): string {
        switch (kind) {
        case "builtin":
            return qsTr("Built-in");
        case "usb":
            return qsTr("USB");
        case "bluetooth":
            return qsTr("Bluetooth");
        case "hdmi":
            return qsTr("HDMI or DisplayPort");
        case "digital":
            return qsTr("Digital");
        case "network":
            return qsTr("Network");
        case "virtual":
            return qsTr("Virtual");
        }
        return "";
    }

    function refresh(): void {
        root.system.query(System.QUERY.audio, "audio.status");
    }

    function choose(nodeId: int): void {
        root.pending = nodeId;
        if (!root.system.act(root.side === "output" ? "output device" : "input device", System.setDefaultDevice(nodeId), "audio.act"))
            root.pending = -1;
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "audio.status":
                root.answered = true;
                // A drag in progress keeps its own value; the next reading follows.
                if (!volume.busy)
                    root.audio = ok ? System.parseAudio(output) : {sinks: [], sources: []};
                break;
            case "audio.names":
                root.naming = false;
                if (ok)
                    root.kinds = Object.assign({}, root.kinds, System.audioKinds(output));
                break;
            case "audio.act":
                root.pending = -1;
                root.refresh();
                break;
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
        visible: root.available
        caption: qsTr("Output & Input")

        Item {
            width: parent.width
            height: Tokens.controlButtonHeight + 2 * Tokens.settingsRowInset

            SegmentedControl {
                x: Tokens.settingsRowInset
                y: Tokens.settingsRowInset
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.controlButtonHeight
                fill: true
                prominent: true
                accessibleName: qsTr("Devices")
                model: [{id: "output", text: qsTr("Output")}, {id: "input", text: qsTr("Input")}]
                value: root.side
                onPicked: id => root.side = id
            }
        }

        SoundDeviceTable {
            model: root.side === "output" ? sinkModel : sourceModel
            accessibleName: root.side === "output" ? qsTr("Output devices") : qsTr("Input devices")
            emptyText: root.side === "output" ? qsTr("No output devices found") : qsTr("No input devices found")
            pending: root.pending
            kindLabel: kind => root.kindLabel(kind)
            roundBottom: true
            onChosen: nodeId => root.choose(nodeId)
        }
    }

    SettingsGroup {
        visible: root.available

        LevelRow {
            id: volume
            system: root.system
            title: root.side === "output" ? qsTr("Output volume") : qsTr("Input volume")
            lowGlyph: root.side === "output" ? "speaker" : "microphone"
            highGlyph: root.side === "output" ? "volume-3" : "microphone"
            lowGlyphSize: root.side === "output" ? Tokens.settingsSliderRowGlyphSize : Tokens.settingsSliderRowSmallGlyphSize
            settable: root.current !== null
            value: root.current ? root.current.volume : 0
            what: "volume"
            tag: "audio.act"
            command: v => System.setVolume(root.current ? root.current.id : -1, v)
        }

        SettingsRow {
            title: qsTr("Mute")

            Toggle {
                accessibleName: root.side === "output" ? qsTr("Mute output") : qsTr("Mute input")
                enabled: root.current !== null
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                checked: root.current ? root.current.muted : false
                onToggled: c => root.system.act("mute", System.setMute(root.current ? root.current.id : -1, c), "audio.act")
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "audio.act"
    }

    DevNote {
        system: root.system
    }
}
