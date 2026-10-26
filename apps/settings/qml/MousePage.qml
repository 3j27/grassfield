pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MT

// Mouse as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Mouse and Trackpad), shown while a mouse is
// connected: the device and the desktop in two cards, then Tracking speed and Natural scrolling; no tabs (Hyprland has no mouse
// gestures). The row under the pointer, or holding the focus, shows its gesture on the device card. The choices go to the
// Grassfield-owned mouse-trackpad.lua next to grassfield.json (MouseTrackpad.js, GF-066), which Trackpad writes too: the tracking
// speed is one for every pointer (Hyprland's input:sensitivity). The shell has Hyprland read its configuration again when the
// file changes (ADR-0027 amendment), so a choice applies at once; the user's own ~/.config/hypr/input.lua still wins.
SettingsPage {
    id: root

    required property var backend

    // Set Up Bluetooth Mouse… opens Bluetooth (Main.qml).
    signal openRequested(string id)

    title: qsTr("Mouse")

    readonly property string path: root.backend.configFile.replace(/[^/]*$/, "mouse-trackpad.lua")
    property var settings: MT.defaults()
    property string writeError: ""
    // The gesture of the row under the pointer or holding the focus, "" for none.
    property string shown: ""

    function reload(): void {
        const file = root.backend.readText(root.path);
        root.settings = file.ok ? MT.parse(file.text) : MT.defaults();
    }

    function change(key: string, value: var): void {
        const next = MT.with_(root.settings, key, value);
        const failure = root.backend.writeText(root.path, MT.serialize(next));
        root.writeError = failure;
        if (failure === "")
            root.settings = next;
    }

    function show(gesture: string, on: bool): void {
        if (on)
            root.shown = gesture;
        else if (root.shown === gesture)
            root.shown = "";
    }

    Component.onCompleted: root.reload()

    GestureHeader {
        device: "mouse"
        gesture: root.shown !== "" ? root.shown : "mouse-tracking"
    }

    SettingsGroup {
        footnote: root.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.writeError.replace(/[.\s]+$/, "")) : ""

        TrackingSpeedRow {
            gesture: "mouse-tracking"
            sensitivity: root.settings.sensitivity
            onPicked: v => root.change("sensitivity", v)
            onShowing: (g, on) => root.show(g, on)
        }

        GestureRow {
            title: qsTr("Natural scrolling")
            subtitle: qsTr("Content tracks finger movement")
            gesture: "mouse-scroll"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Natural scrolling")
                checked: root.settings.mouse_natural_scroll
                onToggled: c => root.change("mouse_natural_scroll", c)
            }
        }
    }

    // The push button under the group, right-aligned (macOS 27: Advanced…, Set Up Bluetooth Mouse… and ?).
    Item {
        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsPushRowGap - Tokens.settingsGroupGap + setUpButton.height

        Button {
            id: setUpButton
            push: true
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: qsTr("Set Up Bluetooth Mouse…")
            onClicked: root.openRequested("bluetooth")
        }
    }
}
