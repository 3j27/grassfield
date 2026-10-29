pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A slider with its title above it and its end labels under it (macOS 27 Size and Magnification). A label sits centred on its
// place along the track; when a longer language makes it reach into the label before it, it moves right to keep a gap (the
// last one stays against the track's end), and one that cannot fit whole inside the track is left out: two labels never
// overlap and none leaves the track.
Item {
    id: root

    property string title: ""
    property alias slider: control
    // The labels: [{text, at}] with `at` 0 to 1 along the knob's travel, in rising order; 0 starts at the track's start, 1
    // ends at its end, any other is centred on its place.
    property var labels: []

    height: parent ? parent.height : 0

    // Lay the labels out. The first and last labels sit at the track's ends, a middle one is centred on its place, moved right
    // to keep a gap from the label before it. A label that does not fit whole between its neighbours and the track's ends is
    // not shown (the first and last come first, then the middle ones in order); the slider's own name and value still tell it.
    function layout(): void {
        const gap = Tokens.settingsDockSliderLabelGap;
        const n = labelRepeater.count;
        const items = [];
        for (let i = 0; i < n; i++)
            items.push(labelRepeater.itemAt(i));
        if (items.some(l => !l) || root.labels.length !== n)
            return;
        const order = [];
        if (n > 0)
            order.push(0);
        if (n > 1)
            order.push(n - 1);
        for (let i = 1; i < n - 1; i++)
            order.push(i);
        const placed = [];
        for (const i of order) {
            const label = items[i];
            const at = root.labels[i].at;
            let x = at === 0 ? 0 : at === 1 ? root.width - label.width : Math.round((control.knobWidth / 2 + at * control.travel - label.width / 2) * 2) / 2;
            // The nearest label shown on each side.
            let before = null;
            let after = null;
            for (const j of placed) {
                if (j < i && (before === null || j > before))
                    before = j;
                if (j > i && (after === null || j < after))
                    after = j;
            }
            if (before !== null)
                x = Math.max(x, items[before].x + items[before].width + gap);
            const fits = x >= 0 && x + label.width <= root.width && (after === null || x + label.width + gap <= items[after].x);
            label.visible = fits;
            if (fits) {
                label.x = x;
                placed.push(i);
            }
        }
    }

    // After the slider's own width and travel settle (they follow this item's width).
    onWidthChanged: Qt.callLater(root.layout)

    Connections {
        target: control

        function onTravelChanged(): void {
            root.layout();
        }
    }

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
