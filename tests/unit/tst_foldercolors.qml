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
        compare(FolderStyle.parse('{"glyph":"a very long pasted sentence"}').glyph, "");
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
}
