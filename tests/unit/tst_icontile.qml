import QtQuick
import QtTest
import Grassfield.Ui

// The own-tile rule of the icon appearance modes (docs/specs/ui.md "Icon shader"): the shape test on the alpha mask of an icon
// (IconTile.measure), the scale that puts a tile on the system plate (IconTile.artScale), and the owner's per-file cache and no-cost Default
// (IconShape, TintedIcon). The masks are synthetic (a function of the pixel), the files are own SVG fixtures.
TestCase {
    id: testCase
    name: "IconTile"
    visible: true
    when: windowShown
    width: 200
    height: 200

    readonly property int n: 96
    readonly property string fixtureDir: Qt.resolvedUrl("../fixtures/icons/")

    function cleanup() {
        Appearance.iconMode = "default";
        IconShape.reset();
    }

    // An n x n RGBA array whose alpha is `alphaAt(u, v)` (u, v in 0..1 over the box, the pixel centre), 255 times it.
    function mask(alphaAt) {
        const out = new Array(testCase.n * testCase.n * 4).fill(0);
        for (let y = 0; y < testCase.n; y++) {
            for (let x = 0; x < testCase.n; x++) {
                const a = alphaAt((x + 0.5) / testCase.n, (y + 0.5) / testCase.n);
                out[(y * testCase.n + x) * 4 + 3] = Math.round(255 * Math.max(0, Math.min(1, a)));
            }
        }
        return out;
    }

    // A rounded square of half side `hs` centred on (cx, cy), corner radius `rad` (box fractions); 1 inside, 0 outside.
    function roundedSquare(cx, cy, hs, rad) {
        return (u, v) => {
            const qx = Math.abs(u - cx) - (hs - rad);
            const qy = Math.abs(v - cy) - (hs - rad);
            return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - rad <= 0 ? 1 : 0;
        };
    }

    // The superellipse |x|^5 + |y|^5 = 1 (the macOS squircle).
    function squircle(cx, cy, hs) {
        return (u, v) => Math.pow(Math.abs(u - cx) / hs, 5) + Math.pow(Math.abs(v - cy) / hs, 5) <= 1 ? 1 : 0;
    }

    function measureOf(alphaAt) {
        return IconTile.measure(testCase.mask(alphaAt), testCase.n, Tokens);
    }

    function test_systemPlateShapeAtSeveralInsetsIsATile() {
        for (const inset of [0, 0.02, 0.04, 0.08, 0.12]) {
            const r = testCase.measureOf(testCase.roundedSquare(0.5, 0.5, 0.5 - inset, 0.225 * (1 - 2 * inset)));
            verify(r.tile, `inset ${inset}: ${r.reason}`);
            fuzzyCompare(r.side, 1 - 2 * inset, 0.02, `side at inset ${inset}`);
        }
    }

    function test_squircleIsATile() {
        const r = testCase.measureOf(testCase.squircle(0.5, 0.5, 0.45));
        verify(r.tile, r.reason);
        fuzzyCompare(r.side, 0.9, 0.02);
    }

    function test_smallRadiusStillATile() {
        const r = testCase.measureOf(testCase.roundedSquare(0.5, 0.5, 0.46, 0.12));
        verify(r.tile, r.reason);
    }

    function test_sharpSquareIsNot() {
        const r = testCase.measureOf((u, v) => Math.abs(u - 0.5) <= 0.45 && Math.abs(v - 0.5) <= 0.45 ? 1 : 0);
        verify(!r.tile);
        compare(r.side, 0);
    }

    function test_circleIsNot() {
        const r = testCase.measureOf((u, v) => Math.hypot(u - 0.5, v - 0.5) <= 0.45 ? 1 : 0);
        verify(!r.tile);
        compare(r.reason.indexOf("fill"), 0);
    }

    function test_folderShapeIsNot() {
        // The body, and a tab on its top left: the shape is no square.
        const body = testCase.roundedSquare(0.5, 0.58, 0.44, 0.06);
        const r = testCase.measureOf((u, v) => body(u, v) > 0 || (u > 0.06 && u < 0.45 && v > 0.12 && v < 0.2) ? 1 : 0);
        verify(!r.tile);
        // A folder that is as high as it is wide (Pebble-like: tab, then a body that reaches the sides) is no tile either.
        const r2 = testCase.measureOf((u, v) => (u > 0.06 && u < 0.94 && v > 0.22 && v < 0.9) || (u > 0.06 && u < 0.42 && v > 0.1 && v < 0.24) ? 1 : 0);
        verify(!r2.tile);
    }

    function test_glyphsAreNot() {
        // A small rounded square (a glyph in a tile of its own that is far from filling the box).
        verify(!testCase.measureOf(testCase.roundedSquare(0.5, 0.5, 0.25, 0.06)).tile);
        // A plus, a ring, nothing.
        verify(!testCase.measureOf((u, v) => (Math.abs(u - 0.5) < 0.08 && Math.abs(v - 0.5) < 0.4) || (Math.abs(v - 0.5) < 0.08 && Math.abs(u - 0.5) < 0.4) ? 1 : 0).tile);
        verify(!testCase.measureOf((u, v) => Math.abs(Math.hypot(u - 0.5, v - 0.5) - 0.38) < 0.06 ? 1 : 0).tile);
        compare(testCase.measureOf(() => 0).reason, "empty");
    }

    function test_shadowDoesNotCount() {
        const tile = testCase.roundedSquare(0.5, 0.48, 0.42, 0.19);
        const shadow = testCase.roundedSquare(0.5, 0.54, 0.44, 0.2);
        const r = testCase.measureOf((u, v) => Math.max(tile(u, v), 0.3 * shadow(u, v)));
        verify(r.tile, r.reason);
        fuzzyCompare(r.side, 0.84, 0.02);
    }

    function test_offCentreIsNot() {
        const r = testCase.measureOf(testCase.roundedSquare(0.6, 0.5, 0.35, 0.16));
        verify(!r.tile);
        compare(r.reason, "off centre");
    }

    function test_artScale() {
        const plate = 1 - 2 * Tokens.iconModeSysPlateInset;
        fuzzyCompare(IconTile.artScale(plate, Tokens), 1, 1e-9);
        fuzzyCompare(IconTile.artScale(0.84, Tokens), plate / 0.84, 1e-9);
        compare(IconTile.artScale(1, Tokens) >= Tokens.iconModeOwnTileScaleMin, true);
        compare(IconTile.artScale(0.01, Tokens), Tokens.iconModeOwnTileScaleMax);
        // Not a tile, unknown: the glyph scale.
        compare(IconTile.artScale(0, Tokens), Tokens.iconModeSysGlyphScale);
        compare(IconTile.artScale(undefined, Tokens), Tokens.iconModeSysGlyphScale);
        compare(IconTile.artScale(null, Tokens), Tokens.iconModeSysGlyphScale);
    }

    function test_cacheClaimsAndEvicts() {
        IconShape.reset();
        compare(IconShape.sideOf("a"), undefined);
        verify(IconShape.claim("a"));
        verify(!IconShape.claim("a"));
        for (let i = 0; i < Tokens.iconModeOwnTileConcurrency - 1; i++)
            verify(IconShape.claim("k" + i));
        verify(!IconShape.claim("over"), "at most iconMode.ownTileConcurrency reads at once");
        IconShape.store("a", 0.84);
        compare(IconShape.sideOf("a"), 0.84);
        verify(IconShape.claim("over"), "a place is free again");
        IconShape.release("over");
        IconShape.store("zero", 0);
        compare(IconShape.sideOf("zero"), 0, "0 is a result (not a tile)");
        verify(!IconShape.claim("zero"));
    }

    Component {
        id: iconComponent

        TintedIcon {
            size: 48
        }
    }

    function test_defaultModeReadsNothing() {
        Appearance.iconMode = "default";
        const icon = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + "own-tile-squircle.svg"});
        verify(icon !== null);
        wait(300);
        compare(icon.effectActive, false);
        compare(icon.shapeWanted, false);
        compare(icon.shapeKnown, true);
        compare(IconShape.busy, 0);
        compare(IconShape.count, 0);
        compare(icon.artScale, Tokens.iconModeSysGlyphScale);
    }

    function test_smallIconsReadNothing() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + "own-tile-squircle.svg", size: Tokens.iconModeMinSize - 1});
        wait(300);
        compare(icon.shapeWanted, false);
        compare(IconShape.count, 0);
    }

    function read(name, mode) {
        Appearance.iconMode = mode;
        const icon = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + name});
        tryVerify(() => icon.shapeKnown, 5000, name + " was not read");
        return icon;
    }

    function test_tileFixturesAreReadOnceAndScaled() {
        const plate = 1 - 2 * Tokens.iconModeSysPlateInset;
        const a = testCase.read("own-tile-squircle.svg", "dark");
        verify(a.ownTile, "squircle fixture");
        fuzzyCompare(a.artScale, plate / 0.86, 0.03);
        const b = testCase.read("own-tile-shadow.svg", "clear");
        verify(b.ownTile, "tile with a shadow fixture");
        fuzzyCompare(b.artScale, plate / 0.8, 0.04);
        compare(IconShape.count, 2);
        // The same file again, in another mode: the cache answers, nothing is read.
        const again = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + "own-tile-squircle.svg"});
        compare(again.shapeKnown, true);
        compare(IconShape.count, 2);
        compare(IconShape.busy, 0);
    }

    Component {
        id: prewarmComponent

        IconShapePrewarm {}
    }

    // PERF-01: the shapes of the listed apps' icons are read ahead of time, one at a time, only in an effect mode; an icon that
    // appears afterwards finds its shape known (no read, no fade-in), and Default reads nothing.
    function test_prewarmReadsAheadAndOnlyInAnEffectMode() {
        const names = ["own-tile-squircle.svg", "own-tile-shadow.svg", "own-circle.svg"];
        const sources = names.map(n => String(testCase.fixtureDir + n));
        Appearance.iconMode = "default";
        const idle = createTemporaryObject(prewarmComponent, testCase, {sources: sources});
        wait(300);
        compare(idle.done, 0, "Default reads nothing");
        compare(IconShape.count, 0);
        Appearance.iconMode = "tinted";
        tryVerify(() => idle.done === 3, 8000, "three files read ahead");
        compare(IconShape.count, 3);
        compare(IconShape.busy, 0);
        const icon = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + "own-tile-squircle.svg"});
        compare(icon.shapeKnown, true, "the icon finds its shape known at once");
        verify(icon.ownTile);
        compare(IconShape.count, 3, "and reads nothing itself");
    }

    function test_glyphFixturesKeepTheGlyphScale() {
        for (const name of ["dark-glyph-no-plate.svg", "logo-no-plate.svg", "own-folder-shape.svg", "own-circle.svg", "own-sharp-square.svg"]) {
            const icon = testCase.read(name, "tinted");
            compare(icon.ownTile, false, name);
            compare(icon.artScale, Tokens.iconModeSysGlyphScale, name);
        }
    }

    function test_theIconIsShownOnlyOnceItsScaleIsKnown() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {source: testCase.fixtureDir + "own-tile-squircle.svg"});
        // The effect does not exist before the icon is shown; the loader is the one that fades.
        tryVerify(() => icon.shapeKnown, 5000);
        tryVerify(() => icon.effectActive, 2000);
    }
}
