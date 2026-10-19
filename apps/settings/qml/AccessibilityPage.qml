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

    // A tool's message is a sentence fragment: no trailing full stop before the sentence's own.
    function fragment(reason: string): string {
        return reason.trim().replace(/[.\s]+$/, "");
    }

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: themeStatus.result === "failed" ? qsTr("The pointer colours could not be applied: %1. The pointer is unchanged.").arg(root.fragment(themeStatus.reason))
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
            PointerPreview {
                anchors.verticalCenter: parent.verticalCenter
                outlineColor: root.outlineColor
                fillColor: root.fillColor
            }
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
            PointerPreview {
                anchors.verticalCenter: parent.verticalCenter
                outlineColor: root.outlineColor
                fillColor: root.fillColor
            }
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
