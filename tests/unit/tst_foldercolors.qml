import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Folder colours: the setting and per-folder precedence, the stored value and the shell-side readers (getfattr output,
// the per-user store), the settings key, and the live switch of a FolderIcon (no layer or effect without a colour).
TestCase {
    id: testCase
    name: "FolderColors"
    visible: true
    when: windowShown
    width: 200
    height: 200

    function cleanup() {
        Appearance.dark = true;
        Appearance.folderColorSetting = "theme";
        Appearance.iconMode = "default";
    }

    function test_settingValidation() {
        compare(FolderStyle.validColor("theme"), true);
        compare(FolderStyle.validColor("accent"), true);
        compare(FolderStyle.validColor("#A0b1C2"), true);
        compare(FolderStyle.validColor("#12345"), false);
        compare(FolderStyle.validColor("blue"), false);
        compare(FolderStyle.validColor(7), false);
        compare(FolderStyle.normalizeColor("bogus"), "theme");
        compare(FolderStyle.recolors("theme"), false);
        compare(FolderStyle.recolors("accent"), true);
        compare(FolderStyle.recolors("#336699"), true);
        compare(FolderStyle.recolors("bogus"), false);
        compare(FolderStyle.colorOf("#336699", "#000000"), "#336699");
        compare(FolderStyle.colorOf("accent", "#000000"), "#000000");
    }

    function test_ownColourWinsOverGlobal() {
        compare(FolderStyle.effectiveColor("", "accent"), "accent");
        compare(FolderStyle.effectiveColor("#336699", "accent"), "#336699");
        compare(FolderStyle.effectiveColor("theme", "accent"), "theme", "a folder can keep the theme colour");
        compare(FolderStyle.effectiveColor("junk", "#336699"), "#336699");
        compare(FolderStyle.effectiveColor("", "junk"), "theme");
    }

    function test_folderIconNames() {
        compare(FolderStyle.isFolderIconName("folder"), true);
        compare(FolderStyle.isFolderIconName("folder-documents"), true);
        compare(FolderStyle.isFolderIconName("inode-directory"), true);
        compare(FolderStyle.isFolderIconName("text-x-generic"), false);
        compare(FolderStyle.isFolderIconName(undefined), false);
    }

    function test_parseStoredValue() {
        const s = FolderStyle.parse('{"v":1,"color":"#FF9500","glyph":"🎵"}');
        compare(s.color, "#ff9500");
        compare(s.glyph, "🎵");
        compare(FolderStyle.parse("not json").color, "");
        compare(FolderStyle.parse('{"color":"red"}').color, "");
        compare(FolderStyle.parse('[1]').glyph, "");
        compare(FolderStyle.parse('{"glyph":"a very long pasted sentence"}').glyph, "a", "one cluster, as Files keeps it");
        compare(FolderStyle.parse('{"glyph":"WWWWWWWWWWWWWWWW"}').glyph, "W");
        compare(FolderStyle.parse('{"glyph":"\u202e"}').glyph, "", "a bidi mark is no symbol");
    }

    function test_getfattrOutput() {
        // {"v":1,"color":"#e5484d","glyph":"★"} in hex
        const json = '{"v":1,"color":"#e5484d","glyph":"★"}';
        let hex = "";
        const bytes = unescape(encodeURIComponent(json));
        for (let i = 0; i < bytes.length; i++)
            hex += ("0" + bytes.charCodeAt(i).toString(16)).slice(-2);
        compare(FolderStyle.hexToText(hex), json);
        const text = "# file: /home/u/Desktop/Music\nuser.grassfield.folder=0x" + hex + "\n\n# file: /home/u/Desktop/plain\n\n# file: /home/u/Desktop/we\\040ird\nuser.grassfield.folder=0x" + hex + "\n";
        const out = FolderStyle.parseGetfattr(text);
        compare(Object.keys(out).length, 1, "escaped paths are skipped, folders without the attribute are absent");
        compare(out["/home/u/Desktop/Music"].color, "#e5484d");
        compare(out["/home/u/Desktop/Music"].glyph, "★");
        compare(FolderStyle.hexToText("zz"), "");
        compare(FolderStyle.hexToText("c3"), "", "invalid UTF-8");
    }

    function test_storeAndPrecedence() {
        const store = FolderStyle.parseStore('{"version":1,"serial":4,"folders":{"/a":{"color":"#3fae5a"},"rel":{"color":"#3fae5a"},"/b":{"color":"nope"}}}');
        compare(store.serial, 4);
        compare(Object.keys(store.folders).length, 1);
        compare(FolderStyle.parseStore("garbage").serial, 0);
        compare(FolderStyle.parseStore('{"version":2,"folders":{"/a":{"color":"#3fae5a"}}}').serial, 0);
        const attrs = {"/a": {color: "#e5484d", glyph: ""}, "/c": {color: "accent", glyph: "x"}};
        compare(FolderStyle.lookup("/a", store.folders, attrs).color, "#3fae5a", "the store's entry wins over the attribute");
        compare(FolderStyle.lookup("/c", store.folders, attrs).glyph, "x");
        compare(FolderStyle.lookup("/none", store.folders, attrs).color, "");
    }

    function test_settingsKey() {
        compare(Store.validate("icons.folderColor", "theme"), "");
        compare(Store.validate("icons.folderColor", "accent"), "");
        compare(Store.validate("icons.folderColor", "#A0b1C2"), "");
        verify(Store.validate("icons.folderColor", "#12345") !== "");
        verify(Store.validate("icons.folderColor", "pink") !== "");
        verify(Store.validate("icons.folderColor", 3) !== "");
        compare(Store.DEFAULTS["icons.folderColor"], "theme");
        const r = Store.setValue(JSON.stringify({version: 1, extra: {a: 1}}), "icons.folderColor", "#e5484d");
        verify(r.ok);
        const data = JSON.parse(r.text);
        compare(Store.read(data, "icons.folderColor"), "#e5484d");
        compare(data.extra.a, 1);
        compare(Store.read({icons: {folderColor: "red"}}, "icons.folderColor"), "theme");
    }

    Component {
        id: iconComponent

        FolderIcon {
            size: 48
        }
    }

    function child(parent, name) {
        for (let i = 0; i < parent.children.length; i++) {
            if (parent.children[i].objectName === name)
                return parent.children[i];
            const deeper = child(parent.children[i], name);
            if (deeper)
                return deeper;
        }
        return null;
    }

    // The layer's effect instance: Qt parents it to the layered item's parent.
    function effectOf(icon) {
        for (let i = 0; i < icon.children.length; i++) {
            if (icon.children[i].colorizationColor !== undefined)
                return icon.children[i];
        }
        return null;
    }

    // The TintedIcon child draws the layer: the recolour exists only when a colour applies.
    function test_liveSwitch() {
        const icon = createTemporaryObject(iconComponent, testCase);
        verify(icon);
        const inner = child(icon, "icon");
        compare(icon.recolored, false);
        compare(inner.layer.enabled, false, "theme colour: no layer, no effect, no cost");
        Appearance.folderColorSetting = "#e5484d";
        compare(icon.recolored, true);
        compare(inner.layer.enabled, true);
        const effect = effectOf(icon);
        verify(effect !== null, "the folder effect exists");
        compare(effect.colorization, Tokens.folderIconColorization);
        compare(effect.colorizationColor.toString(), Qt.color("#e5484d").toString());
        Appearance.folderColorSetting = "accent";
        compare(effect.colorizationColor.toString(), Qt.color(Appearance.colors.accent).toString());
        Appearance.folderColorSetting = "theme";
        compare(inner.layer.enabled, false);
    }

    function test_ownColourOverridesTheGlobalSetting() {
        const icon = createTemporaryObject(iconComponent, testCase, {folderColor: "#3fae5a"});
        verify(icon);
        compare(icon.recolored, true, "a folder with its own colour is recoloured while the global colour is the theme's");
        Appearance.folderColorSetting = "#e5484d";
        compare(icon.folderTint.toString(), Qt.color("#3fae5a").toString());
        icon.folderColor = "theme";
        compare(icon.recolored, false);
        icon.folderColor = "";
        compare(icon.recolored, true);
    }

    function test_glyphShowsOnlyWhenSet() {
        const icon = createTemporaryObject(iconComponent, testCase);
        const glyph = child(icon, "glyph");
        compare(icon.hasGlyph, false);
        icon.folderGlyph = "★";
        compare(icon.hasGlyph, true);
        compare(glyph.text, "★");
    }

    function test_modeStillWorksUnderTheFolderColour() {
        const icon = createTemporaryObject(iconComponent, testCase);
        Appearance.iconMode = "dark";
        compare(icon.mode, "dark");
        Appearance.folderColorSetting = "#e5484d";
        compare(icon.recolored, true);
    }

    // "1F468 200D 1F469" -> the string of those code points.
    function fromCodePoints(hex) {
        let s = "";
        for (const h of hex.split(" ")) {
            if (h === "")
                continue;
            const cp = parseInt(h, 16);
            s += cp > 0xFFFF ? String.fromCodePoint(cp) : String.fromCharCode(cp);
        }
        return s;
    }

    // The symbol rule's shared vectors (tests/fixtures/glyph-vectors.json, the same file FolderStyleLogic::normalizeGlyph
    // is held to in tests/unit/files/tst_folderstyle.cpp GlyphRuleSharedVectors): the preview is what is saved.
    function test_glyphRuleSharedVectors() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../fixtures/glyph-vectors.json"), false);
        request.send();
        const vectors = JSON.parse(request.responseText).vectors;
        verify(vectors.length > 100, "vectors read: " + vectors.length);
        for (const v of vectors) {
            const got = FolderStyle.normalizeGlyph(fromCodePoints(v.input));
            compare(got, fromCodePoints(v.expected), v.name);
            if (v.emoji !== null)
                compare(FolderStyle.isEmoji(got), v.emoji, v.name + " (emoji)");
            compare(FolderStyle.normalizeGlyph(got), got, v.name + " (stable)");
        }
        let zalgo = "e";
        for (let i = 0; i < 16; i++)
            zalgo += "\u0301";
        compare(FolderStyle.normalizeGlyph(zalgo), "", "over 16 UTF-16 units");
        compare(FolderStyle.normalizeGlyph(zalgo.slice(0, 16)), zalgo.slice(0, 16));
    }

    function test_emojiOrPlainSymbol() {
        compare(FolderStyle.isEmoji("\u{1F3B5}"), true);
        compare(FolderStyle.isEmoji("\u2764\uFE0F"), true);
        compare(FolderStyle.isEmoji("\u2B50"), true);
        compare(FolderStyle.isEmoji("\u2705"), true);
        compare(FolderStyle.isEmoji("\u2605"), false);
        compare(FolderStyle.isEmoji("\u266A"), false);
        compare(FolderStyle.isEmoji("A"), false);
    }

    // A hostile value cannot draw outside the icon: the symbol is one cluster and is clipped to the icon box.
    function test_hostileGlyphStaysInsideTheIcon() {
        const icon = createTemporaryObject(iconComponent, testCase, {folderGlyph: "WWWWWWWWWWWWWWWW"});
        compare(icon.glyph, "W");
        const box = child(icon, "glyphBox");
        verify(box.clip, "clipped");
        compare(box.width, icon.width);
        compare(box.height, icon.height);
        const glyph = child(icon, "glyph");
        verify(glyph.width <= icon.width);
        icon.folderGlyph = "\u202eevil";
        compare(icon.hasGlyph, false, "a bidi override is no symbol");
    }

    // Emoji keep their colours and are opaque; a plain symbol is an engraved, opaque shade of the folder colour.
    function test_emojiOpaquePlainSymbolEngraved() {
        const icon = createTemporaryObject(iconComponent, testCase, {folderColor: "#e5484d", folderGlyph: "\u{1F3B5}"});
        const glyph = child(icon, "glyph");
        compare(icon.glyphIsEmoji, true);
        compare(Qt.color(icon.glyphColor).a, 1, "no alpha on an emoji");
        icon.folderGlyph = "\u2605";
        compare(icon.glyphIsEmoji, false);
        compare(Qt.color(icon.glyphColor).a, 1);
        // A darker shade of the same hue: red stays red.
        const c = Qt.color(icon.glyphColor);
        verify(c.r >= c.g && c.r >= c.b, "same hue");
        verify(c.r < Qt.color("#e5484d").r, "darker than the folder colour");
    }

    function contrast(a, b) {
        return FolderStyle.contrastRatio(FolderStyle.rgbOf(a), FolderStyle.rgbOf(b));
    }

    // A2: a plain symbol reaches 3:1 against the folder plate (icons >= 3:1, docs/testing/visual.md). The model of the
    // plate (the folder colour times the mode's measured factor) is checked for the seven tag colours, the accent, the theme
    // colour and custom hexes (white, black, yellow), in light and dark appearance and in the four icon modes (Tinted
    // with the accent and with custom icon tints).
    function test_glyphContrastModel() {
        const tints = ["#e5484d", "#f5883b", "#e6b422", "#3fae5a", "#3e7bfa", "#8e5bea", "#8a8f98", "#ffffff", "#000000", "#ffd60a", "#7f7f7f", "#00ff00", "#0000ff"];
        const modeTints = ["accent", "#e5484d", "#3e7bfa", "#8a8f98", "#ffd60a"];
        for (const dark of [true, false]) {
            Appearance.dark = dark;
            const all = tints.concat([String(Appearance.colors.accent)]);
            for (const mode of ["default", "dark", "clear", "tinted"]) {
                for (const mt of modeTints) {
                    const modeTint = mt === "accent" ? String(Appearance.colors.accent) : mt;
                    if (mode !== "tinted" && mt !== "accent")
                        continue;
                    for (const tint of all) {
                        const plate = FolderStyle.plateOf(true, tint, mode, modeTint, Tokens);
                        const shade = FolderStyle.glyphShade(true, tint, mode, modeTint, Tokens);
                        const r = FolderStyle.contrastRatio(FolderStyle.rgbOf(shade), plate);
                        verify(r >= Tokens.folderIconGlyphMinContrast, "tint " + tint + " " + mode + "/" + mt + (dark ? " dark" : " light") + ": " + r.toFixed(2));
                    }
                    const themePlate = FolderStyle.plateOf(false, "", mode, modeTint, Tokens);
                    const themeShade = FolderStyle.glyphShade(false, "", mode, modeTint, Tokens);
                    verify(FolderStyle.contrastRatio(FolderStyle.rgbOf(themeShade), themePlate) >= Tokens.folderIconGlyphMinContrast, "theme " + mode + "/" + mt);
                }
            }
        }
    }

    // The plates MEASURED in nested captures (tests/visual/folder_glyph_contrast.py, before this change, Files icon view,
    // 64 px icons, Tinted with the accent of the appearance): the shade chosen for that folder colour and mode reaches 3:1
    // against the real plate.
    function test_glyphContrastAgainstMeasuredPlates() {
        const dk = String(Tokens.colorDark.accent), lt = String(Tokens.colorLight.accent);
        const measured = [
            // tint (null = the theme's own folder), mode, icon tint, measured plate
            ["#e5484d", "default", dk, "#e0474b"], ["#3e7bfa", "default", dk, "#3d78f5"], ["#f5883b", "default", dk, "#f0853a"], ["#e6b422", "default", dk, "#e1b021"],
            ["#3fae5a", "default", dk, "#3eaa58"], ["#8e5bea", "default", dk, "#8b59e5"], ["#8a8f98", "default", dk, "#878c95"], ["#ffffff", "default", dk, "#fafafa"],
            ["#000000", "default", dk, "#000000"], ["#ffd60a", "default", dk, "#fad20a"], [null, "default", dk, "#a4caee"],
            ["#e5484d", "dark", dk, "#b5393d"], ["#3e7bfa", "dark", dk, "#3161c6"], ["#ffffff", "dark", dk, "#cacaca"], [null, "dark", dk, "#7fa3c6"],
            ["#e5484d", "tinted", dk, "#cb4044"], ["#3e7bfa", "tinted", dk, "#376dde"], ["#ffffff", "tinted", dk, "#e2e2e2"], [null, "tinted", dk, "#63df86"],
            ["#e5484d", "tinted", lt, "#80282b"], ["#3e7bfa", "tinted", lt, "#23458c"], ["#f5883b", "tinted", lt, "#894c21"], ["#e6b422", "tinted", lt, "#816513"],
            ["#3fae5a", "tinted", lt, "#236232"], ["#8e5bea", "tinted", lt, "#503383"], ["#8a8f98", "tinted", lt, "#4d5055"], ["#ffffff", "tinted", lt, "#8f8f8f"],
            ["#ffd60a", "tinted", lt, "#8f7806"], [null, "tinted", lt, "#2f934f"],
            ["#000000", "clear", dk, "#060708"], ["#000000", "clear", lt, "#353636"], ["#e5484d", "clear", dk, "#e34c52"], ["#e5484d", "clear", lt, "#ff7b80"],
            ["#ffffff", "clear", lt, "#ffffff"], ["#ffd60a", "clear", lt, "#ffff40"]
        ];
        for (const m of measured) {
            // The rows of the other icon modes were measured on the previous (MultiEffect) mode pipeline; the modes now draw
            // through shaders/icon.frag, modelled and checked against rendered pixels (tst_iconshader test_folderModelMatchesTheShader).
            if (m[1] !== "default")
                continue;
            const shade = FolderStyle.glyphShade(m[0] !== null, m[0] === null ? "" : m[0], m[1], m[2], Tokens);
            const r = contrast(shade, m[3]);
            verify(r >= Tokens.folderIconGlyphMinContrast, String(m[0]) + " " + m[1] + ": " + shade + " on " + m[3] + " = " + r.toFixed(2));
        }
    }

    function test_blackFolderGetsALightSymbol() {
        const shade = Qt.color(FolderStyle.glyphShade(true, "#000000", "default", "#4daf69", Tokens));
        verify(shade.r > 0.3, "lightened: " + shade);
    }

    // ---- The plate is computed from samples of the raw icon, not assumed (A2 on any icon theme) ----

    function test_sampleBox() {
        const w = 4, h = 4, data = [];
        for (let i = 0; i < w * h; i++)
            data.push(i < 8 ? 200 : 100, i < 8 ? 200 : 100, i < 8 ? 200 : 100, 255);
        const s = FolderStyle.sampleBox(data, w, h, 0, 0, 4, 4, 12);
        compare(s.length, 4 * 16, "one sample per pixel of a box smaller than the grid");
        verify(Math.abs(s[0] - 200 / 255) < 1e-9 && Math.abs(s[4 * 15] - 100 / 255) < 1e-9);
        const grid = FolderStyle.sampleBox(new Array(100 * 100 * 4).fill(255), 100, 100, 10, 10, 90, 90, 12);
        compare(grid.length, 4 * 144, "at most n x n samples whatever the box");
        compare(FolderStyle.sampleBox(data, w, h, 10, 10, 20, 20, 12), null, "a box outside the image");
        compare(FolderStyle.sampleBox([9, 9, 9, 0], 1, 1, 0, 0, 1, 1, 12), null, "fully transparent");
    }

    function test_plateSummary() {
        const samples = [];
        for (let i = 0; i < 16; i++)
            samples.push(i < 8 ? 200 / 255 : 100 / 255, i < 8 ? 200 / 255 : 100 / 255, i < 8 ? 200 / 255 : 100 / 255, 1);
        const p = FolderStyle.plateSummary(samples, [0, 0, 0]);
        verify(Math.abs(p.dark[0] - 100 / 255) < 1e-6, "darkest quarter");
        verify(Math.abs(p.light[0] - 200 / 255) < 1e-6, "lightest quarter");
        verify(Math.abs(p.hue[0] - 150 / 255) < 1e-6, "mean");
        // Translucent: composited over the backdrop given.
        const t = FolderStyle.plateSummary([1, 1, 1, 0.5], [0, 0, 0]);
        verify(Math.abs(t.dark[0] - 0.5) < 1e-6, "over black");
        const u = FolderStyle.plateSummary([1, 1, 1, 0.5], [1, 1, 1]);
        verify(Math.abs(u.dark[0] - 1) < 1e-6, "over white");
        compare(FolderStyle.plateSummary([], [0, 0, 0]), null);
    }

    // The WhiteSur folder plate under the symbol as measured on the raw icon (nested capture, default mode, theme colour):
    // #74cbf5. Default is the identity; a recolour is Qt's MultiEffect arithmetic (checked against the compiled shader). The
    // icon modes are shaders/icon.frag for a pixel of a plate-less icon (a folder is one): the expected values are derived
    // here by hand from the shader's formulas, and tests/unit/tst_iconshader.qml compares the model with the rendered pixels.
    function test_effectSamplesAreTheShaderArithmetic() {
        const raw = [0x74 / 255, 0xcb / 255, 0xf5 / 255, 1];
        const near = (rgb, hex, tol) => {
            const want = FolderStyle.rgbOf(hex);
            return Math.abs(rgb[0] - want[0]) <= tol && Math.abs(rgb[1] - want[1]) <= tol && Math.abs(rgb[2] - want[2]) <= tol;
        };
        const dk = String(Tokens.colorDark.accent);
        // Dark: the artwork darkened and a little desaturated, dark parts lifted (shaders/icon.frag, derived here by hand)
        const rawRgb = FolderStyle.rgbOf("#74cbf5");
        const lc = 0.2126 * rawRgb[0] + 0.7152 * rawRgb[1] + 0.0722 * rawRgb[2];
        const dd = rawRgb.map(v => (lc + (v - lc) * Tokens.iconModeDarkArtSaturation) * Tokens.iconModeDarkArtScale);
        const ld = 0.2126 * dd[0] + 0.7152 * dd[1] + 0.0722 * dd[2];
        const x = Math.min(1, ld / Tokens.iconModeDarkArtLiftRange);
        const darkWant = dd.map(v => v + Tokens.iconModeDarkArtLift * (1 - x * x * (3 - 2 * x)));
        const darkMode = FolderStyle.plateThrough(raw, "dark", dk, false, "", [0, 0, 0], Tokens, true).dark;
        verify(Math.abs(darkMode[0] - darkWant[0]) < 0.005 && Math.abs(darkMode[1] - darkWant[1]) < 0.005 && Math.abs(darkMode[2] - darkWant[2]) < 0.005, "dark mode " + FolderStyle.hexOf(darkMode));
        // The artwork keeps its hue: still a blue (b > g > r)
        verify(darkMode[2] > darkMode[1] && darkMode[1] > darkMode[0], "dark mode keeps the colour identity");
        // Dark, red folder: the recolour (MultiEffect arithmetic) of the darkened folder; a red stays red
        const redDark = FolderStyle.plateThrough(raw, "dark", dk, true, "#e5484d", [0, 0, 0], Tokens, true).dark;
        verify(redDark[0] > redDark[1] * 2 && redDark[0] > redDark[2] * 2, "dark mode, red " + FolderStyle.hexOf(redDark));
        // default mode, red folder: measured #d14246; blue folder #3970e5; white folder #e9e9e9
        verify(near(FolderStyle.plateThrough(raw, "default", dk, true, "#e5484d", [0, 0, 0], Tokens).dark, "#d14246", 0.01), "default red");
        verify(near(FolderStyle.plateThrough(raw, "default", dk, true, "#3e7bfa", [0, 0, 0], Tokens).dark, "#3970e5", 0.012), "default blue");
        verify(near(FolderStyle.plateThrough(raw, "default", dk, true, "#ffffff", [0, 0, 0], Tokens).dark, "#e9e9e9", 0.012), "default white");
        // Tinted, dark appearance: the luminance of the artwork on the two-tone ramp of the tint.
        const t = FolderStyle.rgbOf(dk);
        const want = t.map(v => v * Tokens.iconModeTintedRampLowDark + ((v + (1 - v) * Tokens.iconModeTintedRampHighDark) - v * Tokens.iconModeTintedRampLowDark) * lc);
        const tinted = FolderStyle.plateThrough(raw, "tinted", dk, false, "", [0, 0, 0], Tokens, true).dark;
        verify(Math.abs(tinted[0] - want[0]) < 0.01 && Math.abs(tinted[1] - want[1]) < 0.01 && Math.abs(tinted[2] - want[2]) < 0.01, "tinted theme " + FolderStyle.hexOf(tinted));
        // Clear, dark appearance: a light ink whose opacity follows the luminance, over the glass of the system plate over the backdrop.
        const inkA = Tokens.iconModeClearAlphaFloor + (1 - Tokens.iconModeClearAlphaFloor) * lc;
        const glassed = Tokens.iconModeClearPlateAlphaDark;   // white glass over the black backdrop
        const clearWant = Tokens.iconModeClearInkDark * inkA + glassed * (1 - inkA);
        const clear = FolderStyle.plateThrough(raw, "clear", dk, false, "", [0, 0, 0], Tokens, true).dark;
        verify(Math.abs(clear[0] - clearWant) < 0.01 && Math.abs(clear[2] - clearWant) < 0.01, "clear dark " + FolderStyle.hexOf(clear) + " want " + clearWant.toFixed(3));
        // an absent colour is the identity of the default mode
        verify(near(FolderStyle.plateThrough(raw, "default", dk, false, "", [0, 0, 0], Tokens).dark, "#74cbf5", 0.003), "default theme");
    }

    // A flat plate of the WhiteSur blue as raw samples.
    readonly property var flatRaw: {
        const out = [];
        for (let i = 0; i < 16; i++)
            out.push(0x74 / 255, 0xcb / 255, 0xf5 / 255, 1);
        return out;
    }

    readonly property var swatches: ["#e5484d", "#f5883b", "#e6b422", "#3fae5a", "#3e7bfa", "#8e5bea", "#8a8f98", "#ffffff", "#000000", "#ffd60a"]

    function shadeFor(mode, dark, color) {
        const modeTint = String(dark ? Tokens.colorDark.accent : Tokens.colorLight.accent);
        const backdrop = FolderStyle.rgbOf(dark ? Tokens.folderIconPlateBackdropDark : Tokens.folderIconPlateBackdropLight);
        const plate = FolderStyle.plateThrough(flatRaw, mode, modeTint, color !== "", color, backdrop, Tokens, dark);
        const shade = FolderStyle.glyphShade(color !== "", color, mode, modeTint, Tokens, plate, dark);
        return {plate: plate, shade: shade, lighter: FolderStyle.relativeLuminance(FolderStyle.rgbOf(shade)) > FolderStyle.relativeLuminance(plate.dark)};
    }

    // A2 for every mode, appearance and colour, from the computed plate: the shade reaches 3:1 against the plate it sits on.
    function test_everyModeAndAppearanceReachesA2() {
        for (const dark of [true, false]) {
            for (const mode of ["default", "dark", "clear", "tinted"]) {
                for (const color of ["", ...swatches]) {
                    const r = shadeFor(mode, dark, color);
                    const against = r.lighter ? r.plate.light : r.plate.dark;
                    const ratio = FolderStyle.contrastRatio(FolderStyle.rgbOf(r.shade), against);
                    verify(ratio >= Tokens.folderIconGlyphMinContrast, mode + (dark ? " dark " : " light ") + (color || "theme") + ": " + r.shade + " " + ratio.toFixed(2));
                }
            }
        }
    }

    // One rule per mode and appearance: the engraving direction is the mode's, a folder takes the other one only when its
    // plate cannot reach the contrast that way. Default, Dark and Clear: darker (only a black folder flips; Dark keeps its colour on the dark system plate) (only
    // the pale plates flip); Tinted: lighter on a dark tint plate (light appearance), darker on a light one (dark appearance).
    function test_oneEngravingRulePerMode() {
        const flips = (mode, dark, wantLighter) => {
            const out = [];
            for (const color of ["", ...swatches]) {
                if (shadeFor(mode, dark, color).lighter !== wantLighter)
                    out.push(color || "theme");
            }
            return out;
        };
        for (const dark of [true, false]) {
            verify(flips("default", dark, false).length <= 2, "default " + dark + ": " + flips("default", dark, false));
            compare(flips("default", dark, false).indexOf("#000000") >= 0, true, "a black folder gets the lighter shade");
            verify(flips("clear", dark, false).length <= 2, "clear " + dark + ": " + flips("clear", dark, false));
            verify(flips("dark", dark, false).length <= 2, "dark " + dark + ": " + flips("dark", dark, false));
        }
        verify(flips("tinted", false, true).length <= 1, "tinted, light appearance: every folder lighter but a white one: " + flips("tinted", false, true));
        verify(flips("tinted", true, false).length <= 2, "tinted, dark appearance: " + flips("tinted", true, false));
        // The same colour always gets the same shade.
        compare(shadeFor("dark", true, "#3e7bfa").shade, shadeFor("dark", true, "#3e7bfa").shade);
    }

    // Every part of the key is cheap: the plate of 100 colours from one set of samples is computed without another read.
    function test_aNewColourNeedsNoNewRead() {
        FolderPlate.reset();
        FolderPlate.claim("k|64");
        FolderPlate.store("k|64", flatRaw);
        const counts = FolderPlate.count;
        const started = Date.now();
        for (let i = 0; i < 100; i++) {
            const color = "#" + ("0" + ((i * 37 + 40) % 200 + 30).toString(16)).slice(-2) + ("0" + ((i * 91 + 60) % 200 + 30).toString(16)).slice(-2) + ("0" + ((i * 53 + 130) % 200 + 30).toString(16)).slice(-2);
            verify(FolderPlate.plateOf("k|64", "default", "", color, true) !== undefined);
        }
        compare(FolderPlate.count, counts, "no further read");
        verify(Date.now() - started < 500, "100 plates in " + (Date.now() - started) + " ms");
        compare(FolderPlate.plateOf("other|64", "default", "", "", true), undefined, "an icon not read yet");
    }

    // One read at a time, application wide.
    function test_oneReadAtATime() {
        FolderPlate.reset();
        verify(FolderPlate.claim("a|64"));
        verify(!FolderPlate.claim("b|64"), "another icon waits");
        verify(!FolderPlate.claim("a|64"), "and so does a second claimant of the same one");
        FolderPlate.store("a|64", flatRaw);
        verify(!FolderPlate.claim("a|64"), "known now");
        verify(FolderPlate.claim("b|64"), "the next one may go");
        FolderPlate.release("b|64");
        verify(FolderPlate.claim("c|64"), "a released claim frees the reader");
        FolderPlate.reset();
    }

    // Past the bound the least recently used quarter goes, not everything: an icon in use keeps its plate.
    function test_cacheEvictsTheLeastRecentlyUsed() {
        FolderPlate.reset();
        FolderPlate.claim("keep|64");
        FolderPlate.store("keep|64", flatRaw);
        for (let i = 0; i < FolderPlate.limit + 10; i++) {
            FolderPlate.store("k" + i + "|64", flatRaw);
            verify(FolderPlate.plateOf("keep|64", "default", "", "", true) !== undefined, "the icon in use is touched");
        }
        verify(FolderPlate.plateOf("keep|64", "default", "", "", true) !== undefined, "the icon in use survived the eviction");
        compare(FolderPlate.plateOf("k0|64", "default", "", "", true), undefined, "the oldest unused one went");
        verify(FolderPlate.count <= FolderPlate.limit, "bounded: " + FolderPlate.count);
        verify(FolderPlate.count > FolderPlate.limit / 2, "a quarter went, not everything: " + FolderPlate.count);
        FolderPlate.reset();
    }

    function test_bucketsAndKeys() {
        compare(FolderPlate.bucketOf(16), 32);
        compare(FolderPlate.bucketOf(48), 64);
        compare(FolderPlate.bucketOf(64), 64);
        compare(FolderPlate.bucketOf(100), 128);
        compare(FolderPlate.bucketOf(1000), 256);
        compare(FolderPlate.rawKeyOf("file:///x.svg", 48), FolderPlate.rawKeyOf("file:///x.svg", 60), "one read per bucket, not per size");
    }

    Component {
        id: measuredComponent

        FolderIcon {
            size: 64
        }
    }

    function plateOfIcon(icon) {
        tryVerify(() => icon.plate !== undefined, 5000, "plate read: " + icon.rawKey);
        return icon.plate;
    }

    // End to end: the raw icon's pixels under the symbol are read (canvas), once per icon file whatever the colours, and the
    // symbol reaches 3:1 on a light icon and on a dark one, with and without a folder colour, in two icon modes.
    function test_plateReadFromTheIconFile() {
        FolderPlate.reset();
        for (const svg of ["folder-light.svg", "folder-dark.svg"]) {
            const before = FolderPlate.count;
            for (const color of ["theme", "#e5484d", "#3fae5a", "#ffffff", "#000000"]) {
                for (const mode of ["default", "dark"]) {
                    const icon = createTemporaryObject(measuredComponent, testCase, {source: Qt.resolvedUrl("fixtures/" + svg), folderColor: color, folderGlyph: "★", mode: mode});
                    verify(icon);
                    const plate = plateOfIcon(icon);
                    verify(plate !== null, "read, not failed: " + svg + " " + color);
                    const against = FolderStyle.relativeLuminance(FolderStyle.rgbOf(icon.glyphColor)) > FolderStyle.relativeLuminance(plate.dark) ? plate.light : plate.dark;
                    const r = FolderStyle.contrastRatio(FolderStyle.rgbOf(icon.glyphColor), against);
                    verify(r >= Tokens.folderIconGlyphMinContrast, svg + " " + color + " " + mode + ": " + r.toFixed(2));
                }
            }
            compare(FolderPlate.count, before + 1, svg + ": ten icons of five colours and two modes, one read");
        }
        // A light theme icon: a dark symbol; a dark one: a lighter symbol than the plate.
        const light = createTemporaryObject(measuredComponent, testCase, {source: Qt.resolvedUrl("fixtures/folder-light.svg"), folderColor: "theme", folderGlyph: "★"});
        const dark = createTemporaryObject(measuredComponent, testCase, {source: Qt.resolvedUrl("fixtures/folder-dark.svg"), folderColor: "theme", folderGlyph: "★"});
        verify(FolderStyle.relativeLuminance(FolderStyle.rgbOf(light.glyphColor)) < FolderStyle.relativeLuminance(plateOfIcon(light).dark));
        verify(FolderStyle.relativeLuminance(FolderStyle.rgbOf(dark.glyphColor)) > FolderStyle.relativeLuminance(plateOfIcon(dark).dark));
    }

    // Two icons asking for one file at once: one reads, both get the plate.
    function test_simultaneousIconsShareOneRead() {
        FolderPlate.reset();
        const props = {source: Qt.resolvedUrl("fixtures/folder-dark.svg"), folderColor: "#e5484d", folderGlyph: "★"};
        const a = createTemporaryObject(measuredComponent, testCase, props);
        const b = createTemporaryObject(measuredComponent, testCase, props);
        plateOfIcon(a);
        tryVerify(() => b.plate !== undefined);
        compare(FolderPlate.count, 1);
    }

    // The symbol is drawn at once, with the estimate, and settles on the measured plate with a fade, no pop; an icon with
    // no file to read keeps the estimate.
    function test_symbolShowsAtOnceAndSettles() {
        FolderPlate.reset();
        Appearance.reduceMotion = false;
        const icon = createTemporaryObject(measuredComponent, testCase, {source: Qt.resolvedUrl("fixtures/folder-dark.svg"), folderColor: "#e5484d", folderGlyph: "★"});
        const box = child(icon, "glyphBox");
        const glyph = child(icon, "glyph");
        verify(box.visible, "visible before the plate is read");
        compare(icon.plate, undefined, "not read yet");
        plateOfIcon(icon);
        tryVerify(() => String(glyph.color) === String(icon.glyphColor), 2000, "settled on the measured shade");
        Appearance.reduceMotion = false;
    }

    function test_noIconFallsBackToTheEstimate() {
        FolderPlate.reset();
        const icon = createTemporaryObject(measuredComponent, testCase, {folderColor: "#e5484d", folderGlyph: "★"});
        const box = child(icon, "glyphBox");
        verify(box.visible, "the symbol shows with the estimate");
        wait(100);
        compare(icon.plate, undefined);
        compare(FolderPlate.count, 0, "nothing was read for an icon without a file");
    }
}
