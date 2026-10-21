import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Accent colour (`accent.color`): setting -> accent/accentText in both appearances, live in Appearance, validation,
// contrast of every pair (A2, 4.5:1 for text on the accent fill) and the dependants (icon tint, folder colour, highlight).
TestCase {
    id: testCase
    name: "Accent"

    readonly property var named: ["blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"]

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function ratio(a, b) {
        const ca = Qt.color(a), cb = Qt.color(b);
        const la = 0.2126 * channel(ca.r) + 0.7152 * channel(ca.g) + 0.0722 * channel(ca.b);
        const lb = 0.2126 * channel(cb.r) + 0.7152 * channel(cb.g) + 0.0722 * channel(cb.b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function cleanup() {
        Appearance.accentSetting = "multicolor";
        Appearance.dark = true;
        Appearance.iconTintSetting = "accent";
        Appearance.folderColorSetting = "theme";
    }

    function test_namesAndNormalize() {
        compare(Accent.NAMES.length, 9);
        compare(Accent.NAMES[0], "multicolor");
        compare(Accent.normalize(undefined), "multicolor");
        compare(Accent.normalize("Blue"), "multicolor");
        compare(Accent.normalize("neon"), "multicolor");
        compare(Accent.normalize("blue"), "blue");
        verify(!Accent.validName(7));
    }

    function test_multicolorKeepsGrassfieldGreen() {
        compare(Accent.resolve("multicolor", true, Tokens), null);
        compare(Accent.resolve("bogus", false, Tokens), null);
        compare(Appearance.colors.accent, Tokens.colorDark.accent);
        Appearance.dark = false;
        compare(Appearance.colors.accent, Tokens.colorLight.accent);
    }

    function test_everyAccentResolvesInBothAppearances() {
        for (const n of testCase.named) {
            const d = Accent.resolve(n, true, Tokens), l = Accent.resolve(n, false, Tokens);
            verify(/^#[0-9A-Fa-f]{6}$/.test(d.accent) && /^#[0-9A-Fa-f]{6}$/.test(d.accentText), n + " dark");
            verify(/^#[0-9A-Fa-f]{6}$/.test(l.accent) && /^#[0-9A-Fa-f]{6}$/.test(l.accentText), n + " light");
            verify(d.accent !== Tokens.colorDark.accent, n + " differs from the Grassfield green");
            verify(ratio(d.accentText, d.accent) >= 4.5, n + " dark text on accent " + ratio(d.accentText, d.accent));
            verify(ratio(l.accentText, l.accent) >= 4.5, n + " light text on accent " + ratio(l.accentText, l.accent));
        }
    }

    function test_appearanceFollowsTheSettingLive() {
        Appearance.accentSetting = "blue";
        compare(Appearance.colors.accent, Tokens.colorAccentDark.blue);
        compare(Appearance.colors.accentText, Tokens.colorAccentDark.blueText);
        compare(Appearance.darkColors.accent, Tokens.colorAccentDark.blue);
        compare(Appearance.lightColors.accent, Tokens.colorAccentLight.blue);
        Appearance.dark = false;
        compare(Appearance.colors.accent, Tokens.colorAccentLight.blue);
        compare(Appearance.colors.accentText, Tokens.colorAccentLight.blueText);
        Appearance.accentSetting = "graphite";
        compare(Appearance.colors.accent, Tokens.colorAccentLight.graphite);
        Appearance.accentSetting = "multicolor";
        compare(Appearance.colors.accent, Tokens.colorLight.accent);
        // The other roles never change.
        compare(Appearance.colors.text, Tokens.colorLight.text);
    }

    function test_highlightFollowsTheAccent() {
        compare(Appearance.highlight, Qt.color(Tokens.colorDark.accent));
        Appearance.accentSetting = "pink";
        compare(Appearance.highlight, Qt.color(Tokens.colorAccentDark.pink));
        compare(Appearance.highlightText, Qt.color(Tokens.colorAccentDark.pinkText));
    }

    function test_iconTintAndFolderColourFollow() {
        Appearance.accentSetting = "orange";
        compare(Appearance.iconTint, Qt.color(Tokens.colorAccentDark.orange));
        Appearance.folderColorSetting = "accent";
        compare(Appearance.folderTint, Qt.color(Tokens.colorAccentDark.orange));
        Appearance.accentSetting = "red";
        compare(Appearance.folderTint, Qt.color(Tokens.colorAccentDark.red));
        // A fixed tint is not the accent.
        Appearance.iconTintSetting = "#8e5bea";
        compare(Appearance.iconTint, Qt.color("#8e5bea"));
    }

    function test_glyphMaskStillWins() {
        Appearance.accentSetting = "green";
        Appearance.devGlyphMode = "white";
        compare(Appearance.colors.accentText, Qt.color("#fffffe"));
        compare(Appearance.darkColors.accentText, Qt.color("#fffffe"));
        Appearance.devGlyphMode = "";
        compare(Appearance.colors.accentText.toString().toLowerCase(), String(Tokens.colorAccentDark.greenText).toLowerCase());
    }

    function test_settingsValidation() {
        for (const n of Accent.NAMES)
            compare(Store.validate("accent.color", n), "", n);
        verify(Store.validate("accent.color", "Blue") !== "");
        verify(Store.validate("accent.color", "#4fb36b") !== "");
        verify(Store.validate("accent.color", 3) !== "");
        compare(Store.DEFAULTS["accent.color"], "multicolor");
        // Parity: the Settings rule accepts exactly the names of Accent.js.
        for (const n of ["", "multicolour", "Graphite"])
            verify(Store.validate("accent.color", n) !== "", n);
    }
}
