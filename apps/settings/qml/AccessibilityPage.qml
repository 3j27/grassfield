import QtQuick
import Grassfield.Ui

// Accessibility (macOS model: Accessibility > Display > Pointer). First slice: Pointer size only; pointer outline and
// fill colours come later (they need the cursor theme to be regenerated, docs/specs/settings.md, Pointer).
SettingsPage {
    id: root

    required property var store

    title: qsTr("Accessibility")

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: qsTr("The pointer changes size as you drag. Apps that are already open keep their size until they are restarted.")

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
    }
}
