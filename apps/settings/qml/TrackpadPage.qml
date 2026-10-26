pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MT

// Trackpad as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Mouse and Trackpad): the device and the desktop
// in two cards, three tabs and their rows; the row under the pointer, or holding the focus, shows its gesture on the device card
// (the tab's first row otherwise). The choices go to the Grassfield-owned mouse-trackpad.lua next to grassfield.json
// (MouseTrackpad.js, GF-066), which Mouse writes too; the shell has Hyprland read its configuration again when the file changes
// (ADR-0031 amendment), so a choice applies at once. The user's own ~/.config/hypr/input.lua still wins.
SettingsPage {
    id: root

    required property var backend

    // Set Up Bluetooth Trackpad… opens Bluetooth (Main.qml).
    signal openRequested(string id)

    title: qsTr("Trackpad")

    readonly property string path: root.backend.configFile.replace(/[^/]*$/, "mouse-trackpad.lua")
    property var settings: MT.defaults()
    property string writeError: ""
    property string tab: "point"
    // The gesture of the row under the pointer or holding the focus, "" for none.
    property string shown: ""
    readonly property string gesture: root.shown !== "" ? root.shown : root.tab === "scroll" ? "scroll" : root.tab === "more" ? "spaces" : "tracking"
    readonly property string errorText: root.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.writeError.replace(/[.\s]+$/, "")) : ""

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

    // A row's gesture while it is under the pointer or holds the focus.
    function show(gesture: string, on: bool): void {
        if (on)
            root.shown = gesture;
        else if (root.shown === gesture)
            root.shown = "";
    }

    Component.onCompleted: root.reload()

    GestureHeader {
        device: "trackpad"
        gesture: root.gesture
        tabs: [{id: "point", text: qsTr("Point & Click")}, {id: "scroll", text: qsTr("Scroll & Zoom")}, {id: "more", text: qsTr("More Gestures")}]
        tab: root.tab
        onTabPicked: id => {
            root.tab = id;
            root.shown = "";
        }
    }

    SettingsGroup {
        visible: root.tab === "point"
        footnote: root.errorText

        TrackingSpeedRow {
            gesture: "tracking"
            sensitivity: root.settings.sensitivity
            onPicked: v => root.change("sensitivity", v)
            onShowing: (g, on) => root.show(g, on)
        }

        GestureRow {
            title: qsTr("Secondary click")
            gesture: root.settings.secondary_click === "corner" ? "corner" : "secondary"
            onShowing: (g, on) => root.show(g, on)

            ComboBox {
                inline: true
                accessibleName: qsTr("Secondary click")
                // With Tap to click, a two-finger tap is a secondary click too (libinput's tap button map).
                model: [{id: "two_finger", text: root.settings.tap_to_click ? qsTr("Click or Tap with Two Fingers") : qsTr("Click with Two Fingers")},
                    {id: "corner", text: qsTr("Click in Bottom Right Corner")}]
                value: root.settings.secondary_click
                onPicked: id => root.change("secondary_click", id)
            }
        }

        GestureRow {
            title: qsTr("Tap to click")
            subtitle: qsTr("Tap with one finger")
            gesture: "tap"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Tap to click")
                checked: root.settings.tap_to_click
                onToggled: c => root.change("tap_to_click", c)
            }
        }
    }

    SettingsGroup {
        visible: root.tab === "scroll"
        footnote: root.errorText

        GestureRow {
            title: qsTr("Natural scrolling")
            subtitle: qsTr("Content tracks finger movement")
            gesture: "scroll"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Natural scrolling")
                checked: root.settings.natural_scroll
                onToggled: c => root.change("natural_scroll", c)
            }
        }
    }

    // The gestures of the session (config/hypr/grassfield/bindings.lua).
    SettingsGroup {
        visible: root.tab === "more"
        footnote: root.errorText

        GestureRow {
            title: qsTr("Swipe between desktops")
            subtitle: qsTr("Swipe left or right with three fingers")
            gesture: "spaces"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Swipe between desktops")
                checked: root.settings.gesture_spaces
                onToggled: c => root.change("gesture_spaces", c)
            }
        }

        GestureRow {
            title: qsTr("Overview")
            subtitle: qsTr("Swipe up with three fingers")
            gesture: "overview"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Overview")
                checked: root.settings.gesture_overview
                onToggled: c => root.change("gesture_overview", c)
            }
        }

        GestureRow {
            title: qsTr("Apps")
            subtitle: qsTr("Pinch with thumb and three fingers")
            gesture: "apps"
            onShowing: (g, on) => root.show(g, on)

            Toggle {
                accessibleName: qsTr("Apps")
                checked: root.settings.gesture_apps
                onToggled: c => root.change("gesture_apps", c)
            }
        }
    }

    // The push button under the groups, right-aligned (macOS 27: Set Up Bluetooth Trackpad… and ?).
    Item {
        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsPushRowGap - Tokens.settingsGroupGap + setUpButton.height

        Button {
            id: setUpButton
            push: true
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: qsTr("Set Up Bluetooth Trackpad…")
            onClicked: root.openRequested("bluetooth")
        }
    }
}
