import QtQuick
import QtTest
import "../../shell/dock/Stacks.js" as Stacks

// Capture defect 8 and review MINOR 3: a label of the Dock stack's Grid view wraps at word boundaries onto two lines and is cut in
// the MIDDLE of the second line, keeping the end of the name (its extension), as macOS stack labels do; never split inside a word
// ("Présentation.od/p"). Stacks.labelLines decides the visible text; the real font metrics measure it here as in the cell of
// shell/overlay/StackPopup.qml (76 pt wide at the caption size). The tests read the text that is shown, not a "truncated" flag.
TestCase {
    id: testCase
    name: "StackLabel"
    width: 400
    height: 400
    visible: true
    when: windowShown

    readonly property real cell: 76

    FontMetrics {
        id: metrics
        font.pixelSize: 11
    }

    function label(name) {
        return Stacks.labelLines(name, t => metrics.advanceWidth(t) <= cell, t => metrics.elidedText(t, Qt.ElideMiddle, cell));
    }

    function widest(text) {
        return Math.max(...text.split("\n").map(l => metrics.advanceWidth(l)));
    }

    function test_aLongSingleWordIsOneLineCutInTheMiddle() {
        const t = label("Présentationtrimestrielledevente.odp");
        compare(t.split("\n").length, 1);
        verify(t.indexOf("…") > 0, "an ellipsis in the middle: " + t);
        verify(t.endsWith(".odp"), "the extension stays: " + t);
        verify(t.startsWith("Prés"), t);
        verify(widest(t) <= cell);
    }

    function test_wordsWrapAtTheirBoundaries() {
        const t = label("Photo de vacances.jpg");
        const lines = t.split("\n");
        compare(lines.length, 2);
        compare(lines.join(" "), "Photo de vacances.jpg");
        verify(t.indexOf("…") < 0);
    }

    // The case of the capture: too long for two lines. The second line is cut in the middle and ends with the extension.
    function test_theSecondLineIsCutInTheMiddleAndKeepsTheExtension() {
        const t = label("Rapport annuel 2025 final version definitive.pdf");
        const lines = t.split("\n");
        compare(lines.length, 2);
        verify("Rapport annuel".startsWith(lines[0]), "the first line is whole words: " + lines[0]);
        verify(lines[1].indexOf("…") > 0, "an ellipsis inside the second line: " + lines[1]);
        verify(!lines[1].startsWith("…"), lines[1]);
        verify(lines[1].endsWith(".pdf"), "the extension stays: " + lines[1]);
        verify(widest(t) <= cell);
    }

    function test_aShortNameIsOneLine() {
        compare(label("Documents"), "Documents");
        compare(label(""), "");
    }

    function test_spacesAreNormalised() {
        compare(label("  a   b  "), "a b");
    }
}
