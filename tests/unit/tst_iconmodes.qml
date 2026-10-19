import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Icon appearance modes (ADR-0014 phase 1): mode -> effect parameters, tint resolution, settings validation, and the
// live switch of a TintedIcon (no effect item in default mode, parameters follow the mode and the tint).
TestCase {
    id: testCase
    name: "IconModes"
    when: windowShown
    width: 200
    height: 200

    readonly property color red: "#e5484d"

    function cleanup() {
        Appearance.iconMode = "default";
        Appearance.iconTintSetting = "accent";
    }

    function test_defaultHasNoEffect() {
        const p = IconModes.effect("default", testCase.red, Tokens);
        compare(p.enabled, false);
        compare(p.colorization, 0);
        compare(p.opacity, 1);
        // Unknown modes are default.
        compare(IconModes.effect("neon", testCase.red, Tokens).enabled, false);
        compare(IconModes.normalizeMode(undefined), "default");
        compare(IconModes.normalizeMode("Dark"), "default");
    }

    function test_darkIsDarkerWithContrastKept() {
        const p = IconModes.effect("dark", testCase.red, Tokens);
        compare(p.enabled, true);
        verify(p.colorization > 0.3 && p.colorization < 1, "darkened by colorizing towards black (hue kept)");
        compare(p.colorizationColor.toString(), Qt.color("#000000").toString(), "never the tint");
        verify(p.contrast > 0, "contrast kept so the glyph stays readable");
        compare(p.opacity, 1);
        verify(p.saturation > -1, "colour is kept");
    }

    function test_clearIsDesaturatedLighterTranslucent() {
        const p = IconModes.effect("clear", testCase.red, Tokens);
        compare(p.enabled, true);
        compare(p.saturation, -1);
        verify(p.brightness > 0);
        verify(p.opacity < 1 && p.opacity >= 0.5, "translucent but meaningful (A2)");
        compare(p.colorization, 0);
    }

    function test_tintedMapsLuminanceToTheTint() {
        const p = IconModes.effect("tinted", testCase.red, Tokens);
        compare(p.enabled, true);
        verify(p.saturation >= 0, "no desaturation after the colorization (it would grey the tint out)");
        verify(p.colorization > 0.9, "luminance mapped to the tint");
        compare(p.opacity, 1, "alpha kept");
        compare(p.colorizationColor.toString(), Qt.color(testCase.red).toString());
    }

    function test_tintResolution() {
        compare(IconModes.validTint("accent"), true);
        compare(IconModes.validTint("#12abEF"), true);
        compare(IconModes.validTint("#12345"), false);
        compare(IconModes.validTint("red"), false);
        compare(IconModes.validTint(5), false);
        compare(IconModes.tintColor("#12abef", "#000000"), "#12abef");
        compare(IconModes.tintColor("accent", "#000000"), "#000000");
        compare(IconModes.tintColor("bogus", "#000000"), "#000000");
    }

    function test_appearanceTintFollowsAccentByDefault() {
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(Appearance.iconTint.toString(), Qt.color("#e5484d").toString());
        Appearance.iconTintSetting = "accent";
        const was = Appearance.dark;
        Appearance.dark = !was;
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString(), "accent follows the appearance");
        Appearance.dark = was;
    }

    function test_settingsKeys() {
        compare(Store.validate("icons.mode", "clear"), "");
        verify(Store.validate("icons.mode", "neon") !== "");
        compare(Store.validate("icons.tint", "accent"), "");
        compare(Store.validate("icons.tint", "#A0b1C2"), "");
        verify(Store.validate("icons.tint", "#12345") !== "");
        verify(Store.validate("icons.tint", 3) !== "");
        compare(Store.DEFAULTS["icons.mode"], "default");
        compare(Store.DEFAULTS["icons.tint"], "accent");
        // Round trip: set, read back, every other key kept.
        const before = JSON.stringify({version: 1, appearance: "light", extra: {a: 1}});
        const r1 = Store.setValue(before, "icons.mode", "tinted");
        verify(r1.ok);
        const r2 = Store.setValue(r1.text, "icons.tint", "#e5484d");
        verify(r2.ok);
        const data = JSON.parse(r2.text);
        compare(Store.read(data, "icons.mode"), "tinted");
        compare(Store.read(data, "icons.tint"), "#e5484d");
        compare(data.appearance, "light");
        compare(data.extra.a, 1);
        // A hand-edited bad value reads as the default.
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.mode"), "default");
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.tint"), "accent");
        verify(!Store.setValue(before, "icons.mode", "neon").ok);
    }

    Component {
        id: iconComponent

        TintedIcon {
            size: 48
        }
    }

    // Live switch: the shell flips Appearance.iconMode; icons already on screen follow without being recreated.
    function test_liveSwitch() {
        const icon = createTemporaryObject(iconComponent, testCase);
        verify(icon);
        const loader = icon.children[1];
        compare(icon.modeActive, false);
        compare(loader.active, false, "default mode: no effect item, no offscreen pass");
        verify(loader.item === null);

        Appearance.iconMode = "dark";
        compare(icon.modeActive, true);
        verify(loader.item !== null);
        compare(loader.item.colorization, Tokens.iconModeDarkColorization);
        compare(loader.item.colorizationColor.toString(), Qt.color(Tokens.iconModeDarkShade).toString());

        Appearance.iconMode = "tinted";
        compare(loader.item.colorization, Tokens.iconModeTintedColorization);
        compare(loader.item.colorizationColor.toString(), Appearance.iconTint.toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(loader.item.colorizationColor.toString(), Qt.color("#e5484d").toString());

        Appearance.iconMode = "clear";
        compare(loader.item.saturation, -1);
        compare(loader.item.opacity, Tokens.iconModeClearOpacity);

        Appearance.iconMode = "default";
        compare(loader.active, false);
        verify(loader.item === null);
    }

    // A per-use override wins over the global setting (previews).
    function test_overrideMode() {
        const icon = createTemporaryObject(iconComponent, testCase, {mode: "clear"});
        verify(icon);
        compare(icon.modeActive, true);
        Appearance.iconMode = "dark";
        compare(icon.mode, "clear");
    }
}
