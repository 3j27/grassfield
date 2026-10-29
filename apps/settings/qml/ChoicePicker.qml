pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A row of pictures to choose from, each with its name under it (macOS 27 Appearance: the Light / Dark / Auto thumbnails,
// the icon styles). The chosen one has an accent ring around its picture and its name in bold and the text colour; the
// others have their name in the secondary colour. One focus stop like a segmented control: Left/Right (and Up/Down) move
// the choice; the keyboard focus is a ring in the focus colour outside the selection ring. The component's box is the
// pictures with room for their rings; the names are centred under them and may reach past it.
// model: [{id, text}]; value: the chosen id; picked(id) on a user change. picture: a Component drawn in each cell, whose
// item gets `choice` (the id).
FocusScope {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""
    property real pictureWidth: 0
    property real pictureHeight: 0
    property real pictureRadius: 0
    // From one picture's left edge to the next one's.
    property real pitch: 0
    property real ringGap: 0
    // The name's baseline below the picture.
    property real captionBaseline: 0
    property Component picture: null

    signal picked(string id)

    readonly property real ringPad: Tokens.settingsChoiceRingWidth + root.ringGap
    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }

    // The widest name (in the chosen weight, the widest one) and the pitch really used: the given one, or more when a longer
    // language would make two names touch; then the names keep a gap and the row grows to the left (it hangs on the right).
    property real widestCaption: 0
    // The room the names may span, the first name's left edge to the last one's right edge (0: no limit): the pitch is capped
    // to fit and a name wider than its share wraps to a second line, centred under its picture. `naturalWidth` is the width it would have without the limit, for a caller that puts
    // the picker on its own line when it does not fit beside a title.
    property real maxWidth: 0
    readonly property real naturalPitch: Math.max(root.pitch, root.widestCaption + Tokens.settingsChoiceCaptionGap)
    readonly property real cap: root.maxWidth > 0 && root.model.length > 0 ? Math.max(root.pictureWidth + 2 * root.ringPad, (root.maxWidth + Tokens.settingsChoiceCaptionGap) / root.model.length) : Infinity
    readonly property real usedPitch: Math.min(root.naturalPitch, root.cap)
    readonly property real captionWidth: Math.max(root.pictureWidth, root.usedPitch - Tokens.settingsChoiceCaptionGap)
    // What the names add to the height when some wrap (the tallest name's height beyond one line).
    property real captionExtra: 0
    readonly property real naturalWidth: root.model.length > 0 ? (root.model.length - 1) * root.naturalPitch + root.pictureWidth + 2 * root.ringPad : 0

    function measureCaptions(): void {
        let widest = 0;
        for (let i = 0; i < measure.count; i++) {
            const item = measure.itemAt(i);
            if (item)
                widest = Math.max(widest, item.implicitWidth);
        }
        root.widestCaption = widest;
    }

    // Each name reports the height it takes and one line's height; the extra is the tallest beyond one line.
    property var nameHeights: ({})

    function noteHeight(index: int, height: real, line: real): void {
        const next = Object.assign({}, root.nameHeights);
        next[index] = Math.max(0, height - line);
        root.nameHeights = next;
        root.captionExtra = Math.max(0, ...Object.values(next));
    }

    // Invisible copies of the names in the bold weight, to know how wide they get.
    Repeater {
        id: measure
        model: root.model
        onItemAdded: root.measureCaptions()
        onItemRemoved: root.measureCaptions()

        delegate: Text {
            required property var modelData
            visible: false
            textFormat: Text.PlainText
            text: modelData.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.settingsCaptionDetailSize
            font.weight: Tokens.typographyMenuBoldWeight
            onImplicitWidthChanged: root.measureCaptions()
        }
    }

    implicitWidth: root.model.length > 0 ? (root.model.length - 1) * root.usedPitch + root.pictureWidth + 2 * root.ringPad : 0
    implicitHeight: root.ringPad + root.pictureHeight + root.captionBaseline + root.captionExtra + Tokens.spacingXs
    activeFocusOnTab: true
    Accessible.role: Accessible.RadioButton
    Accessible.name: root.accessibleName
    Accessible.description: root.currentIndex >= 0 ? root.model[root.currentIndex].text : ""
    Accessible.focusable: true

    function step(direction: int): void {
        if (root.model.length === 0)
            return;
        const next = Math.max(0, Math.min(root.model.length - 1, (root.currentIndex < 0 ? 0 : root.currentIndex) + direction));
        if (next !== root.currentIndex)
            root.picked(root.model[next].id);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    Repeater {
        model: root.model

        delegate: Item {
            id: cell

            required property var modelData
            required property int index
            readonly property bool selected: cell.index === root.currentIndex
            readonly property real captionHeight: caption.height
            onCaptionHeightChanged: root.noteHeight(cell.index, cell.captionHeight, lineMetrics.height)
            Component.onCompleted: root.noteHeight(cell.index, cell.captionHeight, lineMetrics.height)

            FontMetrics {
                id: lineMetrics
                font: caption.font
            }

            x: root.ringPad + cell.index * root.usedPitch
            y: root.ringPad
            width: root.pictureWidth
            height: root.pictureHeight + root.captionBaseline
            Accessible.role: Accessible.RadioButton
            Accessible.name: cell.modelData.text
            Accessible.checkable: true
            Accessible.checked: cell.selected
            Accessible.onPressAction: root.picked(cell.modelData.id)

            // The keyboard focus: outside the selection ring, set off from it, in the focus colour.
            Rectangle {
                x: -(root.ringPad + Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline)
                y: x
                width: root.pictureWidth - 2 * x
                height: root.pictureHeight - 2 * x
                radius: root.pictureRadius - x
                color: "transparent"
                border.width: Tokens.controlFocusOutline
                border.color: Appearance.focusRingColor
                visible: cell.selected && root.activeFocus
            }

            // The selection ring, in the accent, a little outside the picture.
            Rectangle {
                x: -root.ringPad
                y: x
                width: root.pictureWidth - 2 * x
                height: root.pictureHeight - 2 * x
                radius: root.pictureRadius - x
                color: "transparent"
                border.width: Tokens.settingsChoiceRingWidth
                border.color: Appearance.colors.accent
                visible: cell.selected
            }

            Loader {
                width: root.pictureWidth
                height: root.pictureHeight
                sourceComponent: root.picture
                onLoaded: item.choice = Qt.binding(() => cell.modelData.id)
            }

            Text {
                id: caption
                textFormat: Text.PlainText
                width: root.captionWidth
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                x: Math.round((root.pictureWidth - width) / 2)
                y: root.pictureHeight + root.captionBaseline - baselineOffset
                text: cell.modelData.text
                color: cell.selected ? Appearance.colors.text : Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsCaptionDetailSize
                font.weight: cell.selected ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.ArrowCursor
                onClicked: {
                    root.forceActiveFocus();
                    root.picked(cell.modelData.id);
                }
            }
        }
    }
}
