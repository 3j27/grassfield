pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A slider with its title above it and its end labels under it (macOS 27 Size and Magnification). A label sits centred on its
// place along the track; when a longer language makes it reach into the label before it, it moves right to keep a gap (the
// last one stays against the track's end), so two labels never overlap.
Item {
    id: root

    property string title: ""
    property alias slider: control
    // The labels: [{text, at}] with `at` 0 to 1 along the knob's travel, in rising order; 0 starts at the track's start, 1
    // ends at its end, any other is centred on its place.
    property var labels: []

    height: parent ? parent.height : 0

    // Lay the labels out from the first: its wanted place, or just after the label before it.
    function layout(): void {
        let edge = -Tokens.settingsDockSliderLabelGap;
        for (let i = 0; i < labelRepeater.count; i++) {
            const label = labelRepeater.itemAt(i);
            if (!label)
                continue;
            const at = root.labels[i].at;
            const wanted = at === 0 ? 0 : at === 1 ? root.width - label.width : Math.round((control.knobWidth / 2 + at * control.travel - label.width / 2) * 2) / 2;
            label.x = Math.max(wanted, edge + Tokens.settingsDockSliderLabelGap);
            edge = label.x + label.width;
        }
    }

    onWidthChanged: root.layout()

    Text {
        y: Tokens.settingsDockSliderTitleBaseline - baselineOffset
        textFormat: Text.PlainText
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Slider {
        id: control
        y: Tokens.settingsDockSliderCenter - height / 2
        width: parent.width
        accessibleName: root.title
    }

    Repeater {
        id: labelRepeater
        model: root.labels

        delegate: Text {
            required property var modelData
            y: Tokens.settingsDockSliderLabelBaseline - baselineOffset
            textFormat: Text.PlainText
            text: modelData.text
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            onWidthChanged: root.layout()
        }

        onItemAdded: root.layout()
    }
}
