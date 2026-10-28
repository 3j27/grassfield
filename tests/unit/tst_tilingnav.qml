import QtQuick
import QtTest
import "../../shell/overlay/TilingNav.js" as TilingNav

// Keyboard navigation of the tiling popover (shell/overlay/TilingNav.js, docs/specs/tiling.md TL26, parity row M24).
TestCase {
    name: "TilingNav"

    // Two glyph sections of four, then Full Screen and one Move to row; `off` lists the indexes that are greyed.
    function entries(off) {
        const out = [];
        for (let s = 0; s < 2; s++) {
            for (let c = 0; c < 4; c++)
                out.push({line: "s" + s, column: c, enabled: true});
        }
        out.push({line: "r0", column: 0, enabled: true});
        out.push({line: "r1", column: 0, enabled: true});
        for (const i of off || [])
            out[i].enabled = false;
        return out;
    }

    function test_firstKeyChoosesTheFirstOrLast() {
        compare(TilingNav.step(entries(), -1, "down"), 0);
        compare(TilingNav.step(entries(), -1, "right"), 0);
        compare(TilingNav.step(entries(), -1, "up"), 9);
        compare(TilingNav.step(entries(), 5, "home"), 0);
        compare(TilingNav.step(entries(), 5, "end"), 9);
        compare(TilingNav.step(entries([0, 1]), -1, "down"), 2, "greyed glyphs are skipped");
    }

    function test_leftAndRightStayInTheLineAndWrap() {
        compare(TilingNav.step(entries(), 0, "right"), 1);
        compare(TilingNav.step(entries(), 3, "right"), 0);
        compare(TilingNav.step(entries(), 0, "left"), 3);
        compare(TilingNav.step(entries(), 4, "left"), 7);
        compare(TilingNav.step(entries([1]), 0, "right"), 2);
        compare(TilingNav.step(entries(), 8, "right"), 8, "a row has no neighbour");
    }

    function test_upAndDownKeepTheColumnAndSkipGreyedLines() {
        compare(TilingNav.step(entries(), 2, "down"), 6);
        compare(TilingNav.step(entries(), 6, "down"), 8);
        compare(TilingNav.step(entries(), 8, "down"), 9);
        compare(TilingNav.step(entries(), 9, "down"), 0, "wraps to the first line, the column nearest the row's");
        compare(TilingNav.step(entries(), 8, "up"), 4, "from a row: the nearest column, the first");
        compare(TilingNav.step(entries(), 0, "up"), 9, "wraps");
        compare(TilingNav.step(entries([4, 5, 6, 7]), 1, "down"), 8, "a greyed section is skipped");
        compare(TilingNav.step(entries([6]), 2, "down"), 5, "the nearest selectable column");
    }

    function test_nothingSelectable() {
        compare(TilingNav.step([], -1, "down"), -1);
        compare(TilingNav.step(entries([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), -1, "down"), -1);
        compare(TilingNav.step(entries(), 3, "escape"), 3);
    }

    // TL26, TL27 (step 4a): a number picks a layout of the Layouts section, a second number a zone of it.
    function test_numberKeysPickALayoutThenAZone() {
        const layouts = [{zones: [1, 2]}, {zones: [1, 2, 3]}, {zones: [1, 2, 3, 4], enabled: false}];
        compare(JSON.stringify(TilingNav.numberPick(layouts, -1, 2)), JSON.stringify({picked: 1, zone: -1}));
        compare(JSON.stringify(TilingNav.numberPick(layouts, 1, 3)), JSON.stringify({picked: 1, zone: 2}), "the third zone of the second layout");
        compare(JSON.stringify(TilingNav.numberPick(layouts, 1, 4)), JSON.stringify({picked: 1, zone: -1}), "no fourth zone: nothing changes");
        compare(JSON.stringify(TilingNav.numberPick(layouts, 0, 1)), JSON.stringify({picked: 0, zone: 0}));
        compare(JSON.stringify(TilingNav.numberPick(layouts, -1, 3)), JSON.stringify({picked: -1, zone: -1}), "a greyed layout is not picked");
        compare(JSON.stringify(TilingNav.numberPick(layouts, -1, 4)), JSON.stringify({picked: -1, zone: -1}), "no fourth layout");
        compare(JSON.stringify(TilingNav.numberPick(layouts, -1, 0)), JSON.stringify({picked: -1, zone: -1}), "0 is no number of the section");
        compare(JSON.stringify(TilingNav.numberPick(layouts, 1, 10)), JSON.stringify({picked: 1, zone: -1}));
        compare(JSON.stringify(TilingNav.numberPick([], -1, 1)), JSON.stringify({picked: -1, zone: -1}));
        compare(JSON.stringify(TilingNav.numberPick(null, -1, 1)), JSON.stringify({picked: -1, zone: -1}));
    }

    function test_digitOfReadsTheDigitKeysAndTheTopRowByPosition() {
        compare(TilingNav.digitOf(Qt.Key_1, 0), 1);
        compare(TilingNav.digitOf(Qt.Key_9, 0), 9);
        compare(TilingNav.digitOf(Qt.Key_Ampersand, 10), 1, "AZERTY: & on the 1 key");
        compare(TilingNav.digitOf(Qt.Key_Eacute, 11), 2, "AZERTY: é on the 2 key");
        compare(TilingNav.digitOf(Qt.Key_Ccedilla, 18), 9);
        compare(TilingNav.digitOf(Qt.Key_0, 19), 0, "0 picks nothing");
        compare(TilingNav.digitOf(Qt.Key_A, 38), 0);
        compare(TilingNav.digitOf(Qt.Key_Escape, 9), 0);
    }
}
