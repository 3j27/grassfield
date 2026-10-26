pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MT

// Mouse & Trackpad (GF-066; macOS System Settings > Mouse and Trackpad). The choices go to a Grassfield-owned file next
// to grassfield.json that the compositor config reads BEFORE the user's own ~/.config/hypr/input.lua, so a value the
// user sets there still wins (config/hypr/grassfield/input.lua).
SettingsPage {
    id: root

    required property var backend

    title: qsTr("Mouse & Trackpad")

    readonly property string path: root.backend.configFile.replace(/[^/]*$/, "mouse-trackpad.lua")
    property var settings: MT.defaults()
    property string writeError: ""

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

    Component.onCompleted: root.reload()

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: root.writeError !== ""
            ? qsTr("The change could not be saved: %1.").arg(root.writeError.replace(/[.\s]+$/, ""))
            : qsTr("Changes apply the next time you log in. Settings you write in your own input.lua take precedence.")

        SettingsRow {
            title: qsTr("Tracking speed")
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Slow")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
            Slider {
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Tracking speed")
                from: -1
                to: 1
                stepSize: 0.05
                value: root.settings.sensitivity
                onMoved: v => root.change("sensitivity", v)
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Fast")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Trackpad")

        SettingsRow {
            title: qsTr("Natural scrolling")
            subtitle: qsTr("Content follows your fingers.")
            Toggle {
                accessibleName: qsTr("Natural scrolling")
                checked: root.settings.natural_scroll
                onToggled: c => root.change("natural_scroll", c)
            }
        }

        SettingsRow {
            title: qsTr("Tap to click")
            subtitle: qsTr("Tap the trackpad with one finger to click.")
            Toggle {
                accessibleName: qsTr("Tap to click")
                checked: root.settings.tap_to_click
                onToggled: c => root.change("tap_to_click", c)
            }
        }

        SettingsRow {
            title: qsTr("Secondary click")
            SegmentedControl {
                accessibleName: qsTr("Secondary click")
                model: [{id: "two_finger", text: qsTr("Two fingers")}, {id: "corner", text: qsTr("Bottom right corner")}]
                value: root.settings.secondary_click
                onPicked: id => root.change("secondary_click", id)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Mouse")

        SettingsRow {
            title: qsTr("Natural scrolling")
            subtitle: qsTr("Content follows the wheel.")
            Toggle {
                accessibleName: qsTr("Natural scrolling, mouse")
                checked: root.settings.mouse_natural_scroll
                onToggled: c => root.change("mouse_natural_scroll", c)
            }
        }
    }
}
