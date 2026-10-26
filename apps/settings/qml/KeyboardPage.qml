pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Bindings.js" as Bindings

// How menus show shortcuts (keyboard.shortcutStyle), then the read-only list of the Grassfield shortcuts, parsed from the
// bindings file.
SettingsPage {
    id: root

    required property var backend
    required property var store

    title: qsTr("Keyboard")

    readonly property var shortcuts: {
        const file = root.backend.readText(root.backend.bindingsFile);
        // The keys forwarded to the focused application (word and line navigation, Command+[ ]) live next to it.
        const forwarded = root.backend.readText(root.backend.bindingsFile.replace(/bindings\.lua$/, "forwarding.lua"));
        return file.ok ? Bindings.parse(file.text + "\n" + (forwarded.ok ? forwarded.text : "")) : [];
    }

    // Menu shortcuts by device (owner decision 2026-10-26, ADR-0024 C-8): the macOS symbols on a Mac, the key names elsewhere.
    SettingsGroup {
        SettingsRow {
            title: qsTr("Shortcuts in menus")
            subtitle: qsTr("Automatic shows the Mac symbols (⌘ for Super) on a Mac or with an Apple keyboard, and the key names on other computers.")
            ComboBox {
                accessibleName: qsTr("Shortcuts in menus")
                model: [{id: "automatic", text: qsTr("Automatic")}, {id: "mac", text: qsTr("Mac Symbols")}, {id: "pc", text: qsTr("Key Names")}]
                value: root.store.value("keyboard.shortcutStyle")
                onPicked: id => root.store.set("keyboard.shortcutStyle", id)
            }
        }
    }

    SettingsGroup {
        visible: root.shortcuts.length === 0
        footnote: qsTr("The shortcuts file could not be read: %1").arg(root.backend.bindingsFile)
    }

    SettingsGroup {
        visible: root.shortcuts.length > 0
        caption: qsTr("Keyboard Shortcuts")
        footnote: qsTr("Shortcuts are read-only here. They are defined in %1.").arg(root.backend.bindingsFile)

        Repeater {
            model: root.shortcuts

            delegate: SettingsRow {
                required property var modelData

                // The file's English description and key names, translated (Bindings.js lists them).
                title: qsTranslate("Bindings", Bindings.uiName(modelData.description))
                valueText: Bindings.translateKeys(modelData.keys, k => qsTranslate("Bindings", k))
            }
        }
    }
}
