import QtQuick
import Grassfield.Ui

// Accessibility (macOS model: Accessibility > Display > Pointer): pointer size, pointer outline colour, pointer fill
// colour and Reset Colour. The colours are stored (pointer.outlineColor, pointer.fillColor); the shell regenerates the
// cursor theme for them and reports how that went in pointer-theme.json (docs/specs/settings.md, Pointer).
SettingsPage {
    id: root

    required property var store
    readonly property string outlineColor: root.store.value("pointer.outlineColor").toLowerCase()
    readonly property string fillColor: root.store.value("pointer.fillColor").toLowerCase()
    readonly property bool customColors: !PointerColors.isDefault(root.outlineColor, root.fillColor)
    readonly property var presets: [
        {color: Tokens.settingsColorSquareWhite, name: qsTr("White")},
        {color: Tokens.settingsColorSquareBlack, name: qsTr("Black")},
        {color: Tokens.iconModeTintColors[0], name: qsTr("Blue")},
        {color: Tokens.iconModeTintColors[1], name: qsTr("Purple")},
        {color: Tokens.iconModeTintColors[2], name: qsTr("Pink")},
        {color: Tokens.iconModeTintColors[3], name: qsTr("Red")},
        {color: Tokens.iconModeTintColors[4], name: qsTr("Orange")},
        {color: Tokens.iconModeTintColors[5], name: qsTr("Yellow")},
        {color: Tokens.iconModeTintColors[6], name: qsTr("Green")}
    ]

    PointerThemeStatus {
        id: themeStatus
        backend: root.store.backend
        configPath: root.store.path
        outline: root.outlineColor
        fill: root.fillColor
    }

    title: qsTr("Accessibility")

    // Why the colours could not be applied, in the user's language; the tool's own message (English, technical) follows
    // on a line of its own.
    function failureText(): string {
        const code = themeStatus.code;
        let sentence = qsTr("The pointer colours could not be applied. The pointer is unchanged.");
        if (code === "builder")
            sentence = qsTr("The pointer colours could not be applied: the cursor builder is not installed. The pointer is unchanged.");
        else if (code === "folder")
            sentence = qsTr("The pointer colours could not be applied: there is no folder for the custom pointer theme. The pointer is unchanged.");
        else if (/^tool:[A-Za-z0-9_-]+$/.test(code))
            sentence = qsTr("The pointer colours could not be applied: %1 is not installed. The pointer is unchanged.").arg(code.substring(5));
        return themeStatus.reason !== "" ? sentence + "\n" + qsTr("Details: %1").arg(themeStatus.reason) : sentence;
    }

    // Accessibility > Display (macOS): Increase Contrast, Reduce Transparency, Reduce Motion and Text Size, all live in the
    // shell. Reduce Transparency and Reduce Motion are the same keys as in Appearance (one setting, two places, as the
    // Quick Settings Appearance section shows them too).
    SettingsGroup {
        caption: qsTr("Display")
        footnote: qsTr("Text Size scales the text of the shell's panels and of Settings; the menu bar and menus keep their size, as on a Mac. Increase Contrast draws borders and separators stronger and secondary text in the primary colour.")

        SettingsRow {
            title: qsTr("Increase Contrast")
            subtitle: qsTr("Stronger borders and separators, full-strength text.")
            Toggle {
                accessibleName: qsTr("Increase Contrast")
                checked: root.store.value("accessibility.increaseContrast")
                onToggled: c => root.store.set("accessibility.increaseContrast", c)
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
            title: qsTr("Reduce Motion")
            subtitle: qsTr("Animations are shortened to quick crossfades, windows and Spaces included.")
            Toggle {
                accessibleName: qsTr("Reduce Motion")
                checked: root.store.value("accessibility.reduceMotion")
                onToggled: c => root.store.set("accessibility.reduceMotion", c)
            }
        }

        SettingsRow {
            title: qsTr("Text Size")
            subtitle: qsTr("The size of the text in the shell's panels and in Settings.")
            SegmentedControl {
                accessibleName: qsTr("Text Size")
                model: [{id: "1", text: qsTr("100%")}, {id: "1.1", text: qsTr("110%")}, {id: "1.2", text: qsTr("120%")}, {id: "1.3", text: qsTr("130%")}]
                value: String(root.store.value("accessibility.textSize"))
                onPicked: id => root.store.set("accessibility.textSize", Number(id))
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: themeStatus.result === "failed" ? root.failureText()
            : themeStatus.result === "building" && root.customColors ? qsTr("Applying the new pointer colours…")
            : qsTr("The pointer changes as you drag, and apps that use the system pointer follow it. Without the Grassfield compositor extension the pointer changes the next time it changes shape. Apps that draw their own pointer keep the previous size and colours until you quit and reopen them.")

        SettingsRow {
            title: qsTr("Pointer size")
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Normal")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
            Slider {
                id: size
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Pointer size")
                from: PointerSize.MIN
                to: PointerSize.MAX
                stepSize: PointerSize.STEP / (PointerSize.MAX - PointerSize.MIN)
                value: root.store.value("pointer.size")
                onMoved: v => {
                    root.store.set("pointer.size", PointerSize.snap(v));
                    size.reset();
                }
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Large")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }

        SettingsRow {
            title: qsTr("Pointer outline colour")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Pointer outline colour")
                color: root.outlineColor
                presets: root.presets
                onEdited: c => root.store.set("pointer.outlineColor", c)
            }
        }

        SettingsRow {
            title: qsTr("Pointer fill colour")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Pointer fill colour")
                color: root.fillColor
                presets: root.presets
                onEdited: c => root.store.set("pointer.fillColor", c)
            }
        }

        SettingsRow {
            title: ""
            // One preview of the pointer in the chosen colours (the pointer is one thing, as in macOS).
            PointerPreview {
                anchors.verticalCenter: parent.verticalCenter
                outlineColor: root.outlineColor
                fillColor: root.fillColor
            }
            Button {
                text: qsTr("Reset Colour")
                enabled: root.customColors
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                onClicked: {
                    root.store.set("pointer.outlineColor", PointerColors.DEFAULT_OUTLINE);
                    root.store.set("pointer.fillColor", PointerColors.DEFAULT_FILL);
                }
            }
        }
    }
}
