import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Appearance as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Appearance): every control writes
// its key (the appearance thumbnails, the glass slider from clear to tinted, the accent swatches and their keys, the text
// highlight, the icon style, the tint and folder colours as pop-ups), the tint row shows only with Tinted, and a stored colour
// in another case still names its palette entry.
TestCase {
    id: testCase
    name: "SettingsAppearance"
    width: 740
    height: 1200
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: ({
                    "appearance": "light",
                    "material.transparency": 0.25,
                    "material.profile": "balanced",
                    "accent.color": "multicolor",
                    "accent.highlight": "automatic",
                    "icons.mode": "default",
                    "icons.tint": "accent",
                    "icons.folderColor": "theme"
                })
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function set(key: string, v: var): void {
                writes.push([key, v]);
                const next = Object.assign({}, values);
                next[key] = v;
                values = next;
            }
        }
    }

    Component {
        id: pageComponent
        SettingsQml.AppearancePage {
            width: 488
        }
    }

    function make() {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store});
        verify(page);
        return {store: store, page: page};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function named(page, name) {
        return find(page, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_appearanceThumbnails() {
        const t = make();
        const picker = named(t.page, "Appearance");
        verify(picker);
        compare(picker.model.map(m => m.id), ["light", "dark", "auto"]);
        compare(picker.currentIndex, 0);
        picker.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(last(t.store), ["appearance", "dark"]);
        compare(picker.currentIndex, 1);
        picker.picked("auto");
        compare(last(t.store), ["appearance", "auto"]);
    }

    function test_glassSliderRunsFromClearToTinted() {
        const t = make();
        const slider = named(t.page, "Transparency");
        verify(slider);
        // macOS: clear glass on the left, tinted on the right; the stored value is the transparency.
        compare(slider.value, 0.75);
        compare(slider.ticks, 2);
        slider.moved(0.4);
        compare(last(t.store), ["material.transparency", 0.6]);
        compare(slider.value, 0.4);
    }

    function test_accentSwatches() {
        const t = make();
        const swatches = named(t.page, "Accent colour");
        verify(swatches);
        compare(swatches.model.length, Accent.NAMES.length);
        compare(swatches.currentIndex, 0);
        swatches.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(last(t.store), ["accent.color", "blue"]);
        keyClick(Qt.Key_Left);
        compare(last(t.store), ["accent.color", "multicolor"]);
        swatches.chosen(8);
        compare(last(t.store), ["accent.color", "graphite"]);
    }

    function test_textHighlightPopup() {
        const t = make();
        const popup = named(t.page, "Text highlight colour");
        verify(popup);
        compare(popup.model[0].id, "automatic");
        compare(popup.model.map(m => m.id).slice(1), Accent.NAMES.slice(1));
        compare(popup.value, "automatic");
        popup.picked("pink");
        compare(last(t.store), ["accent.highlight", "pink"]);
    }

    function test_iconStyleAndTintRow() {
        const t = make();
        const style = named(t.page, "Icon style");
        verify(style);
        const tint = named(t.page, "Tint colour");
        verify(tint);
        verify(!tint.parent.parent.visible, "the tint row shows only with Tinted");
        style.picked("tinted");
        compare(last(t.store), ["icons.mode", "tinted"]);
        verify(tint.parent.parent.visible);
        tint.picked(Tokens.iconModeTintColors[2]);
        compare(last(t.store), ["icons.tint", Tokens.iconModeTintColors[2]]);
    }

    function test_folderColourNamesItsPaletteEntry() {
        const t = make();
        const folder = named(t.page, "Folder colour");
        verify(folder);
        compare(folder.model.map(m => m.id).slice(0, 2), ["accent", "theme"]);
        compare(folder.value, "theme");
        // A colour stored in lower case still names its entry (the pop-up shows it, not a blank).
        t.store.set("icons.folderColor", Tokens.iconModeTintColors[0].toLowerCase());
        compare(folder.value, Tokens.iconModeTintColors[0]);
        verify(folder.current !== null);
        folder.picked("accent");
        compare(last(t.store), ["icons.folderColor", "accent"]);
    }

    function test_glassEffects() {
        const t = make();
        const profile = named(t.page, "Glass effects");
        verify(profile);
        profile.picked("reduced");
        compare(last(t.store), ["material.profile", "reduced"]);
    }
}
