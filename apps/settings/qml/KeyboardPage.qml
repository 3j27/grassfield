pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Bindings.js" as Bindings
import "Keyboard.js" as Keyboard

// Keyboard as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Keyboard): Key repeat rate and Delay until
// repeat side by side; how menus show shortcuts (keyboard.shortcutStyle) and Keyboard Shortcuts… (the Grassfield shortcuts,
// read-only, in a sheet); Text Input > Input Sources with Edit…. The repeat and the layouts go to the Grassfield-owned
// keyboard.lua next to grassfield.json (Keyboard.js), which holds only what was chosen here: the session's values (Omarchy's
// 40 and 250, the layout of /etc/vconsole.conf) are shown until then. The shell has Hyprland read its configuration again when
// the file changes (ADR-0031 amendment), so a choice applies at once; the user's own input.lua still wins.
SettingsPage {
    id: root

    required property var backend
    required property var store

    // Main.qml opens the sheets; the Input Sources sheet hands its changes back (setSources).
    signal shortcutsRequested(var shortcuts)
    signal sourcesRequested(var sources, var layouts)

    title: qsTr("Keyboard")

    readonly property string path: root.backend.configFile.replace(/[^/]*$/, "keyboard.lua")
    property var choices: ({})
    property string writeError: ""

    readonly property var shortcuts: {
        const file = root.backend.readText(root.backend.bindingsFile);
        // The keys forwarded to the focused application (word and line navigation, Command+[ ]) live next to it.
        const forwarded = root.backend.readText(root.backend.bindingsFile.replace(/bindings\.lua$/, "forwarding.lua"));
        return file.ok ? Bindings.parse(file.text + "\n" + (forwarded.ok ? forwarded.text : "")) : [];
    }
    readonly property var layouts: Keyboard.parseLayouts(root.backend.readText("/usr/share/X11/xkb/rules/base.lst").text)
    readonly property var sources: root.choices.sources ?? Keyboard.sessionSources(root.backend.readText("/etc/vconsole.conf").text)
    readonly property int rateIndex: Keyboard.nearestIndex(Keyboard.RATES, root.choices.rate ?? Keyboard.SESSION_RATE)
    readonly property int delayIndex: Keyboard.nearestIndex(Keyboard.DELAYS, root.choices.delay ?? Keyboard.SESSION_DELAY)

    function reload(): void {
        const file = root.backend.readText(root.path);
        root.choices = file.ok ? Keyboard.parse(file.text) : {};
    }

    function change(key: string, value: var): void {
        const next = Object.assign({}, root.choices);
        next[key] = value;
        const failure = root.backend.writeText(root.path, Keyboard.serialize(next));
        root.writeError = failure;
        if (failure === "")
            root.choices = next;
    }

    // InputSourcesSheet's answer: the new list, the first is the one in use at login.
    function setSources(list: var): void {
        root.change("sources", list.slice(0, Keyboard.MAX_LAYOUTS));
    }

    Component.onCompleted: root.reload()

    SettingsGroup {
        footnote: root.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.writeError.replace(/[.\s]+$/, "")) : ""

        Item {
            width: parent.width
            height: Tokens.settingsKeyboardRepeatHeight

            Repeater {
                model: [
                    {x: Tokens.settingsRowInset, title: qsTr("Key repeat rate"), stops: Keyboard.RATES.length, index: root.rateIndex, low: qsTr("Off"),
                        lowStop: qsTr("Slow"), high: qsTr("Fast"), key: "rate"},
                    {x: Tokens.settingsKeyboardRepeatSecondX, title: qsTr("Delay until repeat"), stops: Keyboard.DELAYS.length, index: root.delayIndex,
                        low: qsTr("Long"), lowStop: "", high: qsTr("Short"), key: "delay"}
                ]

                delegate: Item {
                    id: column

                    required property var modelData

                    x: column.modelData.x
                    width: Tokens.settingsKeyboardRepeatSliderWidth
                    height: parent.height

                    Text {
                        textFormat: Text.PlainText
                        y: Tokens.settingsKeyboardRepeatTitleBaseline - baselineOffset
                        width: parent.width
                        elide: Text.ElideRight
                        text: column.modelData.title
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }

                    Slider {
                        id: slider
                        y: Tokens.settingsKeyboardRepeatSliderCenter - height / 2
                        width: parent.width
                        accessibleName: column.modelData.title
                        from: 0
                        to: column.modelData.stops - 1
                        stops: column.modelData.stops
                        value: column.modelData.index
                        onMoved: v => root.change(column.modelData.key, (column.modelData.key === "rate" ? Keyboard.RATES : Keyboard.DELAYS)[Math.round(v)])
                    }

                    Repeater {
                        // The first label under the first stop, Slow under the second (the rate's), the last at the end.
                        model: [{text: column.modelData.low, at: 0, align: "left"}, {text: column.modelData.lowStop, at: 1, align: "center"},
                            {text: column.modelData.high, at: column.modelData.stops - 1, align: "right"}].filter(l => l.text !== "")

                        delegate: Text {
                            required property var modelData
                            readonly property real stopX: slider.knobWidth / 2 + modelData.at / (column.modelData.stops - 1) * slider.travel

                            textFormat: Text.PlainText
                            x: modelData.align === "left" ? 0 : modelData.align === "right" ? column.width - width : stopX - width / 2
                            y: Tokens.settingsKeyboardRepeatLabelBaseline - baselineOffset
                            text: modelData.text
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                            Accessible.ignored: true
                        }
                    }
                }
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Shortcuts in menus")
            subtitle: qsTr("Automatic shows the symbols (⌘ for Super) when the computer or its keyboard has them on its keys, and the key names otherwise.")

            ComboBox {
                inline: true
                accessibleName: qsTr("Shortcuts in menus")
                model: [{id: "automatic", text: qsTr("Automatic")}, {id: "mac", text: qsTr("Symbols")}, {id: "pc", text: qsTr("Key Names")}]
                value: root.store.value("keyboard.shortcutStyle")
                onPicked: id => root.store.set("keyboard.shortcutStyle", id)
            }
        }

        SettingsRow {
            implicitHeight: (Positioner.index > 0 ? 1 : 0) + Tokens.settingsPushRowHeight

            Button {
                push: true
                text: qsTr("Keyboard Shortcuts…")
                onClicked: root.shortcutsRequested(root.shortcuts)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Text Input")

        SettingsRow {
            title: qsTr("Input Sources")
            implicitHeight: Tokens.settingsPushRowHeight

            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Tokens.settingsGroupLabelWidth)
                elide: Text.ElideRight
                text: root.sources.map(s => Keyboard.sourceName(s, root.layouts.names)).join(", ")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Button {
                push: true
                text: qsTr("Edit…")
                onClicked: root.sourcesRequested(root.sources, root.layouts)
            }
        }
    }
}
