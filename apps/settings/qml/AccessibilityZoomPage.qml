import QtQuick
import Grassfield.Ui

// Accessibility > Zoom (macOS): the compositor magnifies the screen around the pointer (Hyprland cursor:zoom_factor);
// accessibility.zoom and accessibility.zoomLevel, which the keys change too.
SettingsPage {
    id: root

    required property var store

    title: qsTr("Zoom")

    // The same steps as the keys (Super + Alt + = and -): 1.5 to 5 in halves; a hand-edited level outside them as it is.
    readonly property var zoomLevels: {
        const now = Number(root.store.value("accessibility.zoomLevel"));
        const levels = [];
        for (let n = 3; n <= 10; n++)
            levels.push(n / 2);
        if (levels.indexOf(now) < 0)
            levels.push(now);
        levels.sort((a, b) => a - b);
        return levels.map(v => ({id: String(v), text: qsTr("%1×").arg(Qt.locale().toString(v, "f", Number.isInteger(v) ? 0 : Number.isInteger(v * 2) ? 1 : 2))}));
    }

    SettingsGroup {
        footnote: qsTr("Super + Alt + 8 turns zoom on or off, Super + Alt + = and Super + Alt + - change the level. The screen is magnified around the pointer.")

        SettingsRow {
            title: qsTr("Zoom")
            subtitle: qsTr("Magnify the screen.")
            Toggle {
                accessibleName: qsTr("Zoom")
                checked: root.store.value("accessibility.zoom")
                onToggled: c => root.store.set("accessibility.zoom", c)
            }
        }

        // A pop-up: eight levels do not fit beside the title as segments.
        SettingsRow {
            title: qsTr("Zoom level")
            ComboBox {
                inline: true
                accessibleName: qsTr("Zoom level")
                model: root.zoomLevels
                value: String(root.store.value("accessibility.zoomLevel"))
                onPicked: id => root.store.set("accessibility.zoomLevel", Number(id))
            }
        }
    }
}
