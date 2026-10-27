import QtQuick
import Grassfield.Ui

// Accessibility > Keyboard (macOS): Sticky Keys and Slow Keys are not offered: the Wayland compositor has no filter for
// them (no Hyprland option, no xkb equivalent outside X11), and a toggle that does nothing would mislead. The rows say so.
SettingsPage {
    id: root

    title: qsTr("Keyboard")

    SettingsGroup {
        caption: qsTr("Hardware")
        footnote: qsTr("Sticky Keys and Slow Keys need support from the compositor, which Hyprland does not have yet.")

        SettingsRow {
            title: qsTr("Sticky Keys")
            valueText: qsTr("Not available")
        }

        SettingsRow {
            title: qsTr("Slow Keys")
            valueText: qsTr("Not available")
        }
    }
}
