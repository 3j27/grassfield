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

    // TL27 (step 4a): a layout of the Layouts section, its zones targets, none in full at rest, their numbers for the keys.
    function test_aLayoutsZonesAreTargets() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: Tokens.tilingLayoutThirds, own: 3, interactive: true, width: Tokens.tilingLayoutGlyphWidth, color: "#000000",
            zoneNames: ["a", "b", "c"]});
        const z = zonesOf(g);
        compare(z.length, 3);
        verify(z.every(r => Math.abs(r.color.a - Tokens.tilingGlyphOtherOpacity) < 0.01), "own past the last zone: none in full");
        compare(g.stroke, Tokens.tilingGlyphStroke, "a larger glyph keeps the popover's line weight");
        compare(g.gap, Tokens.tilingGlyphGap);
        compare(z[1].Accessible.name, "b");
        const hovered = [];
        const clicked = [];
        g.zoneHovered.connect(i => hovered.push(i));
        g.zoneClicked.connect(i => clicked.push(i));
        const middle = z[2].mapToItem(testCase, z[2].width / 2, z[2].height / 2);
        mouseMove(testCase, middle.x, middle.y);
        mouseClick(testCase, middle.x, middle.y);
        compare(clicked.join(","), "2");
        verify(hovered.indexOf(2) >= 0);
        mouseMove(testCase, 199, 199);
        compare(hovered[hovered.length - 1], -1, "left: -1");
        // Not interactive (the glyph sections): no click goes through a zone.
        g.interactive = false;
        mouseClick(testCase, middle.x, middle.y);
        compare(clicked.join(","), "2");
    }

    // ADR-0036 D69: a zone the window does not fit is drawn unavailable (fainter than a light zone) and takes no click; the
    // others still do.
    function test_aDisabledZoneIsGreyAndTakesNoClick() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: Tokens.tilingLayoutLeftQuarters, own: 3, interactive: true, width: Tokens.tilingLayoutGlyphWidth,
            color: "#000000", disabledZones: [1, 2]});
        const z = zonesOf(g);
        compare(z.length, 3);
        fuzzyCompare(z[0].color.a, Tokens.tilingGlyphOtherOpacity, 0.01, "an available zone at rest: light");
        fuzzyCompare(z[1].color.a, Tokens.tilingGlyphOtherOpacity * Tokens.materialDisabledOpacity, 0.01, "a disabled zone: fainter");
        const clicked = [];
        g.zoneClicked.connect(i => clicked.push(i));
        const at = r => r.mapToItem(testCase, r.width / 2, r.height / 2);
        mouseClick(testCase, at(z[1]).x, at(z[1]).y);
        mouseClick(testCase, at(z[0]).x, at(z[0]).y);
        compare(clicked.join(","), "0", "only the available zone");
        g.own = 1;
        fuzzyCompare(z[1].color.a, Tokens.tilingGlyphOtherOpacity * Tokens.materialDisabledOpacity, 0.01, "never in full, even under the keyboard");
    }

    function test_numberedShowsTheZoneNumbers() {
        const g = createTemporaryObject(glyphComponent, testCase, {zones: Tokens.tilingLayoutQuarters, own: 4, numbered: true, width: Tokens.tilingLayoutGlyphWidth});
        const numbers = zonesOf(g).map(r => r.children.find(c => c.text !== undefined)).map(t => t.visible ? t.text : "");
        compare(numbers.join(","), "1,2,3,4");
        g.numbered = false;
        verify(zonesOf(g).every(r => !r.children.find(c => c.text !== undefined).visible));
    }
}
