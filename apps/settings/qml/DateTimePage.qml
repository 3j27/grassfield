pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "General.js" as General

// General > Date & Time (the structure of the macOS 15 capture, docs/audits/settings-parity-2026-10-26.md § Date & Time):
// automatic time and its source; the date and time (set by hand while the automatic time is off) and the 24-hour clock; the
// time zone and the closest city. timedate1 and timesync1 are read over D-Bus; every change goes to timedate1 through polkit
// (ADR-0026) and the page reads the state again when it answered. The 24-hour clock is the menu bar's (menubar.clockHours).
// Not built (docs/specs/settings.md): the time zone from the location, the Lock Screen's own 24-hour switch, editing the source.
SettingsPage {
    id: root

    required property var backend
    required property var system
    required property var store

    // The time is to be set by hand: Main.qml opens SetDateTimeSheet with the zone's wall clock and hands the answer back
    // to setWallClock().
    signal setRequested(var wall)

    title: qsTr("Date & Time")

    property var time: null
    property var zones: []
    // When the state was read (Date.now()): the clock runs on from timedate1's time.
    property real readAt: 0
    property real now: Date.now()
    // The change sent to timedate1 until it answered ("ntp", "set", "zone"): the polkit dialog may be up.
    property string pending: ""
    // The last change, whose group shows the error if it failed.
    property string lastOp: ""

    readonly property var zone: root.time && root.backend ? root.backend.zoneInfo(root.time.zone) : ({})
    readonly property real offsetSec: root.zone.offsetSeconds ?? 0
    readonly property bool clock24: General.uses24Hour(root.store.value("menubar.clockHours"), Qt.locale().timeFormat(Locale.ShortFormat))
    readonly property string error: root.system.errors["time.act"] !== undefined ? qsTr("The change could not be made: %1.").arg(root.system.errors["time.act"]) : ""

    // The zone's wall clock now.
    function wall(): var {
        return General.wallClock(General.msOf(root.time) + (root.now - root.readAt), root.offsetSec);
    }

    // "Oct 24, 2026 at 11:01:00", in the UI language (the date pattern is the translators', the macOS medium date).
    function dateTimeText(): string {
        if (!root.time)
            return "";
        const w = root.wall();
        const date = Qt.locale().toString(w, qsTr("MMM d, yyyy"));
        const clock = Qt.locale().toString(w, root.clock24 ? "HH:mm:ss" : qsTr("h:mm:ss AP"));
        return qsTr("%1 at %2").arg(date).arg(clock);
    }

    function apply(op: string, what: string, spec: var): void {
        root.lastOp = op;
        if (root.system.act(what, spec, "time.act"))
            root.pending = op;
    }

    function setWallClock(wall: var): void {
        root.apply("set", "date and time", General.timeSet(General.fromWallClock(wall, root.offsetSec)));
    }

    Component.onCompleted: {
        root.system.queryBus("time.state", "time.state");
        root.system.queryBus("time.zones", "time.zones");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "time.state") {
                root.time = ok ? General.parseTime(output) : null;
                root.readAt = Date.now();
                root.now = root.readAt;
            } else if (tag === "time.zones") {
                root.zones = ok ? General.parseZones(output) : [];
            } else if (tag === "time.act") {
                root.pending = "";
                root.system.queryBus("time.state", "time.state");
            }
        }
    }

    // The clock in the second group runs; the state is read again now and then (the synchronisation, a change elsewhere).
    Timer {
        interval: 1000
        repeat: true
        running: root.visible && root.time !== null
        onTriggered: root.now = Date.now()
    }
    Timer {
        interval: Tokens.settingsSystemRefreshMs
        repeat: true
        running: root.visible && root.pending === ""
        onTriggered: root.system.queryBus("time.state", "time.state")
    }

    SettingsGroup {
        footnote: root.lastOp === "ntp" ? root.error : ""

        SettingsRow {
            title: qsTr("Set time and date automatically")
            subtitle: root.pending === "ntp" ? qsTr("Waiting for permission…") : ""
            Toggle {
                accessibleName: qsTr("Set time and date automatically")
                enabled: root.time !== null && root.time.canNtp && root.pending === ""
                checked: root.time !== null && root.time.ntp
                onToggled: c => root.apply("ntp", "automatic time", General.timeNtp(c))
            }
        }
        SettingsRow {
            title: qsTr("Source")
            enabled: root.time !== null && root.time.ntp
            opacity: enabled ? 1 : Tokens.materialDisabledOpacity
            valueText: root.time ? (root.time.server || root.time.servers[0] || qsTr("None")) : ""
        }
    }

    SettingsGroup {
        footnote: root.lastOp === "set" ? root.error : ""

        SettingsRow {
            title: qsTr("Date and time")
            subtitle: root.pending === "set" ? qsTr("Waiting for permission…") : ""
            valueText: root.dateTimeText()

            Button {
                visible: root.time !== null && !root.time.ntp
                enabled: root.pending === ""
                push: true
                text: qsTr("Set…")
                Accessible.name: qsTr("Set the date and time")
                onClicked: root.setRequested(root.wall())
            }
        }
        SettingsRow {
            title: qsTr("24-hour time")
            Toggle {
                accessibleName: qsTr("24-hour time")
                checked: root.clock24
                onToggled: c => root.store.set("menubar.clockHours", c ? "24" : "12")
            }
        }
    }

    SettingsGroup {
        footnote: root.lastOp === "zone" ? root.error : ""

        SettingsRow {
            title: qsTr("Time zone")
            valueText: root.time ? (root.zone.longName || root.time.zone || qsTr("Unknown")) : ""
        }
        SettingsRow {
            title: qsTr("Closest city")
            subtitle: root.pending === "zone" ? qsTr("Waiting for permission…") : ""

            CityField {
                enabled: root.time !== null && root.zones.length > 0 && root.pending === ""
                backend: root.backend
                zones: root.zones
                current: root.time ? root.time.zone : ""
                onPicked: zone => root.apply("zone", "time zone", General.timeZone(zone))
            }
        }
    }

    DevNote {
        system: root.system
    }
}
