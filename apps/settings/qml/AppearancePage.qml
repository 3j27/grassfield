import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store

    title: qsTr("Appearance")

    SettingsGroup {
        SettingsRow {
            title: qsTr("Appearance")
            subtitle: qsTr("Light or dark windows, menus and panels. Auto is light by day and dark at night.")
            SegmentedControl {
                accessibleName: qsTr("Appearance")
                model: [{id: "light", text: qsTr("Light")}, {id: "dark", text: qsTr("Dark")}, {id: "auto", text: qsTr("Auto")}]
                value: root.store.value("appearance")
                onPicked: id => root.store.set("appearance", id)
            }
        }
    }

    SettingsGroup {
        id: accentGroup
        caption: qsTr("Accent colour")
        footnote: qsTr("Colour of buttons, selections, toggles and focus rings in the shell and in the apps. Multicolour is the Grassfield green. The highlight colour follows the accent.")

        readonly property string setting: root.store.value("accent.color")
        readonly property var names: [qsTr("Multicolour"), qsTr("Blue"), qsTr("Purple"), qsTr("Pink"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"), qsTr("Green"), qsTr("Graphite")]
        // One round swatch per accent, in the colour it has in the current appearance; the chosen one is marked.
        readonly property var model: {
            const out = [];
            for (let i = 0; i < Accent.NAMES.length; i++) {
                const n = Accent.NAMES[i];
                const base = Appearance.dark ? Tokens.colorDark : Tokens.colorLight;
                const r = Accent.resolve(n, Appearance.dark, Tokens);
                out.push({color: r ? r.accent : base.accent, name: accentGroup.names[i], state: accentGroup.setting === n ? 2 : 0});
            }
            return out;
        }

        SettingsRow {
            title: qsTr("Accent colour")
            SwatchRow {
                accessibleName: qsTr("Accent colour")
                caption: accentGroup.model.filter(m => m.state === 2).map(m => m.name).join("")
                model: accentGroup.model
                activeFocusOnTab: true
                onChosen: index => {
                    currentIndex = index;
                    root.store.set("accent.color", Accent.NAMES[index]);
                }
            }
        }
    }

    SettingsGroup {
        id: iconGroup
        caption: qsTr("Icon appearance")
        footnote: qsTr("Applies to app and file icons in the Dock, Apps, Search, the desktop and Files. Tinted maps each icon to shades of one colour.")

        readonly property string mode: root.store.value("icons.mode")
        readonly property string tintSetting: root.store.value("icons.tint")
        readonly property var tintNames: [qsTr("Blue"), qsTr("Purple"), qsTr("Pink"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"), qsTr("Green"), qsTr("Graphite")]
        // Accent first (the default), then the palette; the chosen one is marked.
        readonly property var tintModel: {
            const out = [{color: Appearance.colors.accent, name: qsTr("Accent"), state: iconGroup.tintSetting === "accent" ? 2 : 0}];
            for (let i = 0; i < Tokens.iconModeTintColors.length; i++) {
                const c = Tokens.iconModeTintColors[i];
                out.push({color: c, name: iconGroup.tintNames[i], state: iconGroup.tintSetting.toLowerCase() === c.toLowerCase() ? 2 : 0});
            }
            return out;
        }

        Item {
            width: parent.width
            height: picker.height + 2 * Tokens.spacingMd

            IconModePicker {
                id: picker
                anchors.centerIn: parent
                accessibleName: qsTr("Icon appearance")
                model: [{id: "default", text: qsTr("Default")}, {id: "dark", text: qsTr("Dark")}, {id: "clear", text: qsTr("Clear")}, {id: "tinted", text: qsTr("Tinted")}]
                value: iconGroup.mode
                onPicked: id => root.store.set("icons.mode", id)
            }
        }

        SettingsRow {
            title: qsTr("Tint colour")
            SwatchRow {
                id: tintRow
                accessibleName: qsTr("Tint colour")
                enabled: iconGroup.mode === "tinted"
                // Disabled: why. Enabled: the name of the chosen colour (SwatchRow shows it when nothing is hovered).
                caption: enabled ? iconGroup.tintModel.filter(m => m.state === 2).map(m => m.name).join("") : qsTr("Choose Tinted to use a tint colour.")
                model: iconGroup.tintModel
                activeFocusOnTab: true
                onActiveFocusChanged: {
                    if (activeFocus && currentIndex < 0) {
                        for (let i = 0; i < model.length; i++) {
                            if (model[i].state === 2)
                                currentIndex = i;
                        }
                    }
                }
                onChosen: index => {
                    currentIndex = index;
                    root.store.set("icons.tint", index === 0 ? "accent" : Tokens.iconModeTintColors[index - 1]);
                }
            }
        }
    }

    SettingsGroup {
        id: folderGroup
        caption: qsTr("Folder colour")
        footnote: qsTr("Applies to every folder icon in Files, the desktop and Get Info. A folder can have its own colour (Files, Customize Folder).")

        readonly property string setting: root.store.value("icons.folderColor")
        // Theme (the icon theme's own colour), Accent (follows the accent), then the palette; the chosen one is marked.
        readonly property var model: {
            const out = [
                {color: Tokens.iconModeSampleTop, name: qsTr("Theme"), state: folderGroup.setting === "theme" ? 2 : 0},
                {color: Appearance.colors.accent, name: qsTr("Accent"), state: folderGroup.setting === "accent" ? 2 : 0}
            ];
            for (let i = 0; i < Tokens.iconModeTintColors.length; i++) {
                const c = Tokens.iconModeTintColors[i];
                out.push({color: c, name: iconGroup.tintNames[i], state: folderGroup.setting.toLowerCase() === c.toLowerCase() ? 2 : 0});
            }
            return out;
        }

        SettingsRow {
            title: qsTr("Folder colour")
            SwatchRow {
                accessibleName: qsTr("Folder colour")
                caption: folderGroup.model.filter(m => m.state === 2).map(m => m.name).join("")
                model: folderGroup.model
                activeFocusOnTab: true
                onActiveFocusChanged: {
                    if (activeFocus && currentIndex < 0) {
                        for (let i = 0; i < model.length; i++) {
                            if (model[i].state === 2)
                                currentIndex = i;
                        }
                    }
                }
                onChosen: index => {
                    currentIndex = index;
                    root.store.set("icons.folderColor", index === 0 ? "theme" : (index === 1 ? "accent" : Tokens.iconModeTintColors[index - 2]));
                }
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
                color: Appearance.windowSecondary
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
            SegmentedControl {
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
