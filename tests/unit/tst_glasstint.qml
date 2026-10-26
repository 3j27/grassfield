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
