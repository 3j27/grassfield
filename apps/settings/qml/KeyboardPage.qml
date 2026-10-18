pragma ComponentBehavior: Bound
import QtQuick
import "Bindings.js" as Bindings

// Read-only list of the Grassfield shortcuts, parsed from the bindings file.
SettingsPage {
    id: root

    required property var backend

    title: qsTr("Keyboard")

    readonly property var shortcuts: {
        const file = root.backend.readText(root.backend.bindingsFile);
        return file.ok ? Bindings.parse(file.text) : [];
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
