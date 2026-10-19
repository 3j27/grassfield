import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Folder colours: the setting and per-folder precedence, the stored value and the shell-side readers (getfattr output,
// the per-user store), the settings key, and the live switch of a FolderIcon (no layer or effect without a colour).
TestCase {
    id: testCase
    name: "FolderColors"
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

    // The symbol rule's shared vectors: FolderStyleLogic::normalizeGlyph (tests/unit/files/tst_folderstyle.cpp,
    // GlyphRuleSharedVectors) answers the same.
    function test_glyphRuleSharedVectors() {
        const music = "\u{1F3B5}", heart = "\u2764\uFE0F", fr = "\u{1F1EB}\u{1F1F7}", keycap = "1\uFE0F\u20E3", eAcute = "e\u0301";
        const vectors = [
            [music, music], [heart, heart], [fr, fr], [fr + "\u{1F1EB}", fr], [keycap, keycap], [eAcute + "x", eAcute],
            ["WWWWWWWWWWWWWWWW", "W"], ["Holiday photos", "H"], ["a\u202e", "a"], ["\u202ea", ""], ["\u200ea", ""], ["a\u200b", "a"],
            ["\u0001a", ""], ["  \u2605  ", "\u2605"], ["\uFFFD", ""]
        ];
        for (const v of vectors)
            compare(FolderStyle.normalizeGlyph(v[0]), v[1], JSON.stringify(v[0]));
        const family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}";
        compare(FolderStyle.normalizeGlyph(family + "x"), family);
        const thumbs = "\u{1F44D}\u{1F3FD}";
        compare(FolderStyle.normalizeGlyph(thumbs + "x"), thumbs);
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
        compare(Qt.color(glyph.color).a, 1, "no alpha on an emoji");
        icon.folderGlyph = "\u2605";
        compare(icon.glyphIsEmoji, false);
        compare(Qt.color(glyph.color).a, 1);
        // A darker shade of the same hue: red stays red.
        const c = Qt.color(glyph.color);
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
            const shade = FolderStyle.glyphShade(m[0] !== null, m[0] === null ? "" : m[0], m[1], m[2], Tokens);
            const r = contrast(shade, m[3]);
            verify(r >= Tokens.folderIconGlyphMinContrast, String(m[0]) + " " + m[1] + ": " + shade + " on " + m[3] + " = " + r.toFixed(2));
        }
    }

    function test_blackFolderGetsALightSymbol() {
        const shade = Qt.color(FolderStyle.glyphShade(true, "#000000", "default", "#4daf69", Tokens));
        verify(shade.r > 0.3, "lightened: " + shade);
    }
}
