pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TextInImages.js" as TextInImages

// The text of an image as macOS Live Text offers it (ADR-0045 OC-2, docs/specs/preview.md P13): laid exactly over the
// picture (ImageView gives it the picture's size, centre and rotation, so a press maps to the picture's own pixels whatever
// the zoom and the quarter turns), an I-beam over the words, a press on a word and a drag select words in reading order,
// across lines; a double click selects the word; a click clears the selection, as macOS's (there is no caret in a picture).
// A press elsewhere clears it too and goes on to the view under it (panning, the double click of Zoom to Fit). The selection is drawn per line in the text highlight colour (Settings >
// Appearance), translucent so that the text stays readable under it. Right button: contextMenuRequested.
Item {
    id: root

    // TextInImages.parseTsv.
    property var page: TextInImages.emptyPage()
    // The selection: the word where the drag started and the one it reached (-1: none; a press sets only the anchor).
    property int anchorWord: -1
    property int focusWord: -1
    readonly property bool hasSelection: TextInImages.range(root.page, root.anchorWord, root.focusWord) !== null
    readonly property bool hasText: root.page.words.length > 0
    // This item's pixels per pixel of the page the tools read.
    readonly property real unit: root.page.width > 0 ? root.width / root.page.width : 0
    // The pointer is over a line of text (the I-beam).
    property bool overText: false

    // In this item's coordinates (the menu host maps them).
    signal contextMenuRequested(real x, real y)

    onPageChanged: root.clear()

    function clear(): void {
        root.anchorWord = -1;
        root.focusWord = -1;
    }
    function selectAll(): void {
        if (!root.hasText)
            return;
        root.anchorWord = 0;
        root.focusWord = root.page.words.length - 1;
    }
    function selectedText(): string {
        return TextInImages.selectionText(root.page, root.anchorWord, root.focusWord);
    }

    Repeater {
        model: root.hasSelection && root.unit > 0 ? TextInImages.selectionBoxes(root.page, root.anchorWord, root.focusWord) : []

        Rectangle {
            required property var modelData
            x: modelData.x * root.unit - Tokens.previewTextSelectionOutset
            y: modelData.y * root.unit - Tokens.previewTextSelectionOutset
            width: modelData.w * root.unit + 2 * Tokens.previewTextSelectionOutset
            height: modelData.h * root.unit + 2 * Tokens.previewTextSelectionOutset
            radius: Tokens.previewTextSelectionRadius
            color: Appearance.withAlpha(Appearance.highlight, Tokens.previewTextSelectionOpacity)
        }
    }

    MouseArea {
        id: area
        objectName: "textArea"
        anchors.fill: parent
        enabled: root.hasText && root.unit > 0
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        // A drag that selects keeps the pointer: the view does not pan under it.
        preventStealing: true
        cursorShape: root.overText || area.pressed ? Qt.IBeamCursor : Qt.ArrowCursor

        onPositionChanged: mouse => {
            root.overText = TextInImages.lineAt(root.page, mouse.x / root.unit, mouse.y / root.unit) >= 0;
            if (area.pressed && root.anchorWord >= 0)
                root.focusWord = TextInImages.wordNear(root.page, mouse.x / root.unit, mouse.y / root.unit);
        }
        onExited: root.overText = false
        onPressed: mouse => {
            if (mouse.button === Qt.RightButton) {
                root.contextMenuRequested(mouse.x, mouse.y);
                return;
            }
            const word = TextInImages.wordAt(root.page, mouse.x / root.unit, mouse.y / root.unit);
            if (word < 0) {
                root.clear();
                mouse.accepted = false;
                return;
            }
            root.anchorWord = word;
            root.focusWord = -1;
        }
        onDoubleClicked: mouse => {
            const word = TextInImages.wordAt(root.page, mouse.x / root.unit, mouse.y / root.unit);
            if (word >= 0) {
                root.anchorWord = word;
                root.focusWord = word;
            }
        }
    }
}
