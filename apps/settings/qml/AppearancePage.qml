import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store

    title: qsTr("Appearance")

    SettingsGroup {
        SettingsRow {
            title: qsTr("Appearance")
            subtitle: qsTr("Light or dark windows, menus and panels.")
            Segmented {
                accessibleName: qsTr("Appearance")
                model: [{id: "light", text: qsTr("Light")}, {id: "dark", text: qsTr("Dark")}]
                // "auto" in the file has no effect in the shell (it renders dark), so nothing is selected for it.
                value: root.store.value("appearance")
                onPicked: id => root.store.set("appearance", id)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Material")
        footnote: qsTr("Transparency applies to the menu bar, Dock, menus and panels. Reduce Transparency makes them opaque.")

        SettingsRow {
            title: qsTr("Transparency")
            Slider {
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Transparency")
                from: 0
                to: 1
                stepSize: 0.05
                value: root.store.value("material.transparency")
                onMoved: v => root.store.set("material.transparency", Math.round(v * 100) / 100)
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.settingsShortcutKeyMinWidth + Tokens.spacingSm
                horizontalAlignment: Text.AlignRight
                text: qsTr("%1%").arg(Math.round(root.store.value("material.transparency") * 100))
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        SettingsRow {
            title: qsTr("Reduce Transparency")
            subtitle: qsTr("Opaque surfaces instead of translucent ones.")
            Toggle {
                accessibleName: qsTr("Reduce Transparency")
                checked: root.store.value("accessibility.reduceTransparency")
                onToggled: c => root.store.set("accessibility.reduceTransparency", c)
            }
        }

        SettingsRow {
            title: qsTr("Material profile")
            subtitle: qsTr("Full uses live previews, Balanced refreshes them less often, Reduced uses still images.")
            Segmented {
                accessibleName: qsTr("Material profile")
                model: [{id: "full", text: qsTr("Full")}, {id: "balanced", text: qsTr("Balanced")}, {id: "reduced", text: qsTr("Reduced")}]
                value: root.store.value("material.profile")
                onPicked: id => root.store.set("material.profile", id)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Motion")

        SettingsRow {
            title: qsTr("Reduce Motion")
            subtitle: qsTr("Animations are shortened to quick crossfades.")
            Toggle {
                accessibleName: qsTr("Reduce Motion")
                checked: root.store.value("accessibility.reduceMotion")
                onToggled: c => root.store.set("accessibility.reduceMotion", c)
            }
        }
    }
}
