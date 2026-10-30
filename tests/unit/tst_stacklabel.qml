import QtQuick
import QtTest

// Capture defect 8: a label of the Dock stack's Grid view wraps at word boundaries and is truncated in the middle (macOS), never
// split inside a word ("Présentation.od/p"). The Text below has the properties of the Grid cell's label in
// shell/overlay/StackPopup.qml (tests/shell/stack_label_wrap.sh holds the two together); the cell is 76 pt wide at the
// caption size.
TestCase {
    id: testCase
    name: "StackLabel"
    width: 400
    height: 400
    visible: true
    when: windowShown

    Component {
        id: label
        Text {
            width: 76
            font.pixelSize: 11
            maximumLineCount: 2
            elide: Text.ElideMiddle
            wrapMode: Text.WordWrap
        }
    }

    function show(text) {
        const t = createTemporaryObject(label, testCase, {text: text});
        verify(t !== null);
        wait(20);
        return t;
    }

    // A name with no space is one line, shortened in the middle: it is never broken into two lines.
    function test_aLongSingleWordIsTruncatedInTheMiddle() {
        const t = show("Présentationtrimestrielledevente.odp");
        compare(t.lineCount, 1);
        verify(t.truncated);
        verify(t.contentWidth <= t.width);
    }

    function test_wordsWrapAtTheirBoundaries() {
        const t = show("Photo de vacances.jpg");
        compare(t.lineCount, 2);
        verify(!t.truncated);
    }

    function test_threeLinesOfWordsAreTruncated() {
        const t = show("Rapport annuel 2025 final version definitive.pdf");
        compare(t.lineCount, 2);
        verify(t.truncated);
    }

    function test_aShortNameIsOneLine() {
        const t = show("Documents");
        compare(t.lineCount, 1);
        verify(!t.truncated);
    }

    // The mode the cell used to have splits a word across two lines.
    function test_wrapAnywhereWouldSplitTheWord() {
        const t = createTemporaryObject(label, testCase, {text: "Présentation.odp", wrapMode: Text.WrapAnywhere});
        wait(20);
        compare(t.lineCount, 2);
        const w = show("Présentation.odp");
        compare(w.lineCount, 1);
    }
}
