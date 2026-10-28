import QtQuick
import QtTest
import Grassfield.Ui

// The tiling glyph (ui/Grassfield/Ui/TileGlyph.qml, docs/specs/tiling.md TL23, TL25): zones in twelfths inside an outline.
TestCase {
    id: testCase
    name: "TileGlyph"
    width: 200
    height: 200
    visible: true
    when: windowShown

    Component {
        id: glyphComponent
        TileGlyph {}
    }

    function zonesOf(glyph) {
        return glyph.children.filter(c => c.border !== undefined && c.color.a > 0); // the outline is transparent inside
    }

    function test_popoverSizeFollowsTheTokens() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: [[0, 0, 12, 12]]});
        compare(g.width, Tokens.tilingGlyphWidth);
        compare(g.height, Math.round(Tokens.tilingGlyphWidth * Tokens.tilingGlyphHeight / Tokens.tilingGlyphWidth));
        compare(g.stroke, Tokens.tilingGlyphStroke);
    }

    function test_zonesShareTheInsideWithAGap() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: [[0, 0, 6, 12], [6, 0, 6, 12]], own: 0, color: "#000000"});
        const z = zonesOf(g);
        compare(z.length, 2);
        const inner = Tokens.tilingGlyphStroke + Tokens.tilingGlyphInset;
        fuzzyCompare(z[0].x, inner, 0.001);
        fuzzyCompare(z[0].y, inner, 0.001);
        fuzzyCompare(z[0].height, g.height - 2 * inner, 0.001);
        fuzzyCompare(z[1].x - (z[0].x + z[0].width), Tokens.tilingGlyphGap, 0.001, "the gap between two zones");
        fuzzyCompare(z[1].x + z[1].width, g.width - inner, 0.001, "the inset on the outline's side");
        // The window's own zone in full, the others light (parity row M19).
        fuzzyCompare(z[0].color.a, 1, 0.01);
        fuzzyCompare(z[1].color.a, Tokens.tilingGlyphOtherOpacity, 0.01);
    }

    function test_ownMinusOneDrawsEveryZoneInFull() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: Tokens.tilingLayoutQuarters, own: -1, color: "#000000"});
        compare(zonesOf(g).length, 4);
        verify(zonesOf(g).every(z => Math.abs(z.color.a - 1) < 0.01));
        compare(zonesOf(createTemporaryObject(glyphComponent, testCase, {zones: [], own: -1})).length, 0, "an empty screen: the outline only");
    }

    function test_aMenuGlyphScalesDownButKeepsAPixelOfOutline() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: [[0, 0, 6, 12]], width: Tokens.menuIconSize});
        compare(g.height, Math.round(Tokens.menuIconSize * Tokens.tilingGlyphHeight / Tokens.tilingGlyphWidth));
        verify(g.stroke >= 1);
        verify(zonesOf(g)[0].width > 0);
    }
}
