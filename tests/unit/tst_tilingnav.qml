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
}
