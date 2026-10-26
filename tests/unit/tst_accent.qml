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
        Appearance.increaseContrast = false;
        Appearance.textScale = 1;
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

    // macOS keeps white text on its accent fill in both appearances (ADR-0024): a selected row, a default button or a checked
    // box uses the light appearance's accent and text colour, also in the dark appearance; 4.5:1 for every accent.
    function test_selectionIsTheLightAccentInBothAppearances() {
        for (const n of ["multicolor"].concat(testCase.named)) {
            Appearance.accentSetting = n;
            const fill = n === "multicolor" ? Tokens.colorLight.accent : Tokens.colorAccentLight[n];
            const text = n === "multicolor" ? Tokens.colorLight.accentText : Tokens.colorAccentLight[n + "Text"];
            for (const dark of [true, false]) {
                Appearance.dark = dark;
                compare(Qt.color(Appearance.colors.selection), Qt.color(fill), n + (dark ? " dark" : " light"));
                compare(Qt.color(Appearance.colors.selectionText), Qt.color(text), n + (dark ? " dark" : " light"));
                verify(ratio(Appearance.colors.selectionText, Appearance.colors.selection) >= 4.5, n + " " + ratio(Appearance.colors.selectionText, Appearance.colors.selection));
            }
        }
        // The multicolor green in the dark appearance: white text, not the dark text of the bright accent.
        Appearance.accentSetting = "multicolor";
        Appearance.dark = true;
        compare(Qt.color(Appearance.colors.selectionText), Qt.color("#ffffff"));
        Appearance.devGlyphMode = "white";
        compare(Qt.color(Appearance.colors.selectionText), Qt.color("#fffffe"));
        Appearance.devGlyphMode = "";
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

    // The keyboard focus ring (UX-09, A11Y-08): one colour for every surface, 3:1 or more as a non-text element against the
    // material tint and against that tint over the extreme wallpapers (the tint alpha floor), for every accent in both
    // appearances, the light appearance's yellow included (it falls back to the text colour).
    function test_focusRingHolds3to1OnEveryAccentInBothAppearances() {
        function over(fg, a, bg) {
            const f = Qt.color(fg), b = Qt.color(bg);
            return Qt.rgba(f.r * a + b.r * (1 - a), f.g * a + b.g * (1 - a), f.b * a + b.b * (1 - a), 1);
        }
        for (const dark of [true, false]) {
            Appearance.dark = dark;
            for (const n of Accent.NAMES) {
                Appearance.accentSetting = n;
                const ring = Appearance.focusRingColor;
                const tint = Appearance.colors.materialTint;
                const alpha = Tokens.materialTintAlphaClamp;
                for (const wallpaper of ["#000000", "#ffffff", Appearance.colors.materialTint]) {
                    const surface = over(tint, alpha, wallpaper);
                    verify(ratio(ring, surface) >= 3, (dark ? "dark " : "light ") + n + " ring " + ring + " on " + surface + ": " + ratio(ring, surface));
                }
            }
        }
        Appearance.dark = false;
        Appearance.accentSetting = "yellow";
        compare(Appearance.focusRingColor.toString(), Qt.color(Tokens.colorLight.text).toString(), "light yellow: the text colour");
        Appearance.accentSetting = "blue";
        compare(Appearance.focusRingColor.toString(), Qt.color(Tokens.colorAccentLight.blue).toString(), "light blue: the accent");
    }

    function test_increaseContrastAndTextSizeFollowTheSettings() {
        const base = Tokens.materialBorderOpacity;
        const body = Tokens.typographyBodySize;
        compare(Appearance.colors.textSecondary, Tokens.colorDark.textSecondary);
        Appearance.increaseContrast = true;
        verify(Tokens.materialBorderOpacity > base * 2, "borders are stronger");
        compare(Appearance.colors.textSecondary, Tokens.colorDark.text);
        Appearance.increaseContrast = false;
        compare(Tokens.materialBorderOpacity, base);
        Appearance.textScale = 1.3;
        compare(Tokens.typographyBodySize, Math.round(body * 1.3));
        verify(Tokens.typographyCaptionSize > 11);
        compare(Tokens.typographyMenuSize, 13, "the menu bar and menus keep their size");
        Appearance.textScale = 1;
        compare(Tokens.typographyBodySize, body);
    }

    function test_accessibilityKeysValidate() {
        compare(Store.validate("accessibility.increaseContrast", true), "");
        verify(Store.validate("accessibility.increaseContrast", "yes") !== "");
        compare(Store.validate("accessibility.textSize", 1.2), "");
        verify(Store.validate("accessibility.textSize", 0.5) !== "");
        verify(Store.validate("accessibility.textSize", 2) !== "");
        compare(Store.DEFAULTS["accessibility.textSize"], 1);
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
