import QtQuick
import QtTest
import Grassfield.Ui

// Adaptive glass (ADR-0024 section 2, G-1 to G-3; GlassTint.js): a class tint raised to keep text at 4.5:1 over the backdrop,
// the worst case (black to white) when the shell does not know it, the class target over a known bare desktop.
TestCase {
    id: testCase

    name: "GlassTint"
    width: 200
    height: 200
    visible: true
    when: windowShown

    Material {
        id: material
        width: 100
        height: 60
        glassClass: "menu"
    }

    function cleanup() {
        Appearance.backdrops = {};
        Appearance.increaseContrast = false;
        material.backdropRect = Qt.rect(0, 0, 0, 0);
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
    }

    function floorOf(dark, lumMin, lumMax, need) {
        const c = dark ? Tokens.colorDark : Tokens.colorLight;
        return GlassTint.floorAlpha(c.materialTint, [c.text, c.textSecondary], c.fill, Tokens.materialFillOpacity, lumMin, lumMax, need);
    }

    // Today's material over any backdrop: the secondary text is the binding constraint (light 0.78, dark 0.82).
    function test_worstCaseFloors() {
        compare(floorOf(false, 0, 1, 4.5), 0.78);
        compare(floorOf(true, 0, 1, 4.5), 0.82);
    }

    function test_targetAlpha() {
        const d = Tokens.materialDefaultTransparency;
        compare(GlassTint.targetAlpha(0.65, 0, d), 1);
        fuzzyCompare(GlassTint.targetAlpha(0.65, d, d), 0.65, 1e-9);
        fuzzyCompare(GlassTint.targetAlpha(0.65, 1, d), 0, 1e-9);
        verify(GlassTint.targetAlpha(0.65, d / 2, d) > 0.65 && GlassTint.targetAlpha(0.65, d / 2, d) < 1);
    }

    function test_unknownBackdropTakesTheWorstCase() {
        Appearance.dark = false;
        compare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "nowhere"), 0.78);
        Appearance.dark = true;
        compare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "nowhere"), 0.82);
        compare(Appearance.glassAlpha("menu", 0, "nowhere"), 1);
        compare(Appearance.glassAlpha("menu", 1, "nowhere"), 0.82);
    }

    // A dark wallpaper behind dark-appearance glass: light text holds on its own, the class target applies.
    function test_knownDarkBackdropInTheDarkAppearance() {
        Appearance.dark = true;
        Appearance.backdrops = {"out": {lumMin: 0.01, lumMax: 0.05}};
        fuzzyCompare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out"), Tokens.glassMenu, 1e-9);
        fuzzyCompare(Appearance.glassAlpha("notification", Tokens.materialDefaultTransparency, "out"), Tokens.glassNotification, 1e-9);
        // A bright wallpaper behind the same glass needs more tint than the target.
        Appearance.backdrops = {"out": {lumMin: 0.6, lumMax: 0.9}};
        verify(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out") > Tokens.glassMenu);
    }

    function test_knownBrightBackdropInTheLightAppearance() {
        Appearance.dark = false;
        Appearance.backdrops = {"out": {lumMin: 0.7, lumMax: 0.9}};
        fuzzyCompare(Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, "out"), Tokens.glassMenu, 1e-9);
    }

    // A 4 x 2 grid over a 400 x 200 output: the left half dark, the right half bright (G-3 per surface).
    readonly property var splitGrid: ({width: 400, height: 200, cols: 4, rows: 2, min: [0.01, 0.01, 0.7, 0.7, 0.01, 0.01, 0.7, 0.7], max: [0.04, 0.05, 0.9, 0.9, 0.04, 0.05, 0.9, 0.9]})

    function test_gridRange() {
        const left = GlassTint.gridRange(splitGrid, Qt.rect(10, 10, 60, 150), 0);
        fuzzyCompare(left.lumMin, 0.01, 1e-9);
        fuzzyCompare(left.lumMax, 0.04, 1e-9);
        // A wider area takes the cells it reaches.
        fuzzyCompare(GlassTint.gridRange(splitGrid, Qt.rect(10, 10, 150, 150), 0).lumMax, 0.05, 1e-9);
        // The blur's reach brings the bright cell beside it in.
        compare(GlassTint.gridRange(splitGrid, Qt.rect(110, 10, 60, 20), 40).lumMax, 0.9);
        // Outside the output: clamped to the edge cells.
        compare(GlassTint.gridRange(splitGrid, Qt.rect(500, -50, 30, 30), 0).lumMin, 0.7);
        // No answer without a grid or an area: the caller keeps the whole output's range.
        compare(GlassTint.gridRange(null, Qt.rect(0, 0, 10, 10), 0), null);
        compare(GlassTint.gridRange(splitGrid, Qt.rect(0, 0, 0, 0), 0), null);
        compare(GlassTint.gridRange({width: 400, height: 200, cols: 4, rows: 2, min: [0], max: [1]}, Qt.rect(0, 0, 10, 10), 0), null);
    }

    function test_gridOf() {
        // 4 x 2 pixels, two cells across: black and white on the left, a mid grey on the right.
        const px = [0, 0, 0, 255, 255, 255, 255, 255, 119, 119, 119, 255, 119, 119, 119, 255, 0, 0, 0, 255, 255, 255, 255, 255, 119, 119, 119, 255, 119, 119, 119, 255];
        const g = GlassTint.gridOf(px, 4, 2, 2, 1, 1920, 1080);
        compare(g.cols, 2);
        compare(g.width, 1920);
        fuzzyCompare(g.min[0], 0, 1e-9);
        fuzzyCompare(g.max[0], 1, 1e-9);
        fuzzyCompare(g.min[1], g.max[1], 1e-9);
        verify(g.min[1] > 0.15 && g.min[1] < 0.2);
    }

    // The glass over the dark half takes the class target; over the bright half it is raised (dark appearance).
    function test_materialUsesTheAreaUnderIt() {
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.9, grid: splitGrid};
        Appearance.backdrops = backs;
        material.backdropRect = Qt.rect(10, 10, 60, 60);
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
        material.backdropRect = Qt.rect(330, 10, 60, 60);
        verify(material.tintAlpha > Tokens.glassMenu);
        // Without an area (and in a window smaller than the output) the whole output's range applies.
        material.backdropRect = Qt.rect(0, 0, 0, 0);
        compare(material.tintAlpha, Appearance.glassAlpha("menu", Tokens.materialDefaultTransparency, material.screenName, Qt.rect(0, 0, 0, 0)));
    }

    // Text straight on the wallpaper (the Notification Center title): the ink that holds 4.5:1 over the whole range, else
    // none (the caller puts glass behind it).
    function test_inkOn() {
        const inks = [Tokens.colorDark.text, Tokens.colorLight.text];
        compare(GlassTint.inkOn({lumMin: 0.01, lumMax: 0.1}, inks, 4.5), Tokens.colorDark.text);
        compare(GlassTint.inkOn({lumMin: 0.6, lumMax: 0.95}, inks, 4.5), Tokens.colorLight.text);
        compare(GlassTint.inkOn({lumMin: 0.02, lumMax: 0.88}, inks, 4.5), "");
        compare(GlassTint.inkOn(null, inks, 4.5), "");
    }

    // Increase Contrast frosts the glass whatever the backdrop and the class (G-8).
    function test_increaseContrastFrosts() {
        Appearance.dark = true;
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.05};
        Appearance.backdrops = backs;
        Appearance.increaseContrast = true;
        compare(material.tintAlpha, Tokens.glassContrastFrost);
        Appearance.increaseContrast = false;
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
    }

    function test_materialFollowsItsClassAndOutput() {
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        compare(material.tintAlpha, 0.82);
        const backs = {};
        backs[material.screenName] = {lumMin: 0.01, lumMax: 0.05};
        Appearance.backdrops = backs;
        fuzzyCompare(material.tintAlpha, Tokens.glassMenu, 1e-9);
        material.glassClass = "";
        compare(material.tintAlpha, Appearance.tintAlpha(Tokens.materialDefaultTransparency));
        material.glassClass = "menu";
    }
}
