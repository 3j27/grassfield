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

    Component {
        id: appearanceThumb
        SettingsQml.AppearanceThumbnail {
            width: Tokens.settingsAppearanceThumbWidth
            height: Tokens.settingsAppearanceThumbHeight
        }
    }

    Component {
        id: saverThumb
        SettingsQml.SaverThumbnail {
            width: Tokens.settingsAppearanceThumbWidth
            height: Tokens.settingsAppearanceThumbHeight
        }
    }

    function all(item, out) {
        for (const c of item.children) {
            out.push(c);
            all(c, out);
        }
        return out;
    }

    // The thumbnails are drawn from the settings.appearanceThumb* and settings.saverThumb* tokens.
    function test_thumbnailsDrawFromTokens() {
        const a = createTemporaryObject(appearanceThumb, testCase, {choice: "auto"});
        const w = a.width;
        const h = a.height;
        const items = all(a, []);
        // The menu, the window and the auto split where the tokens put them.
        verify(items.some(i => i.x === Math.round(w * Tokens.settingsAppearanceThumbMenuX) && i.y === Math.round(h * Tokens.settingsAppearanceThumbMenuY)
            && i.width === Math.round(w * Tokens.settingsAppearanceThumbMenuWidth)));
        verify(items.some(i => i.x === Math.round(w * Tokens.settingsAppearanceThumbWindowX) && i.y === Math.round(h * Tokens.settingsAppearanceThumbWindowY)));
        verify(items.some(i => i.clip && i.x === Math.round(w * Tokens.settingsAppearanceThumbAutoSplit)));
        compare(Tokens.settingsAppearanceThumbLightX.length, 3);
        const s = createTemporaryObject(saverThumb, testCase, {choice: "clock"});
        const clock = all(s, []).find(i => i.font !== undefined && i.visible);
        verify(clock);
        compare(clock.font.pixelSize, Math.round(s.height * Tokens.settingsSaverThumbClockSize));
        compare(clock.x, Math.round(s.width * Tokens.settingsSaverThumbClockOnlyX));
        s.choice = "slideshow";
        const photos = all(s, []).filter(i => i.rotation !== 0 && i.visible);
        compare(photos.length, 1);
        compare(photos[0].rotation, -Tokens.settingsSaverThumbPhotoTilt);
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

    // The names under the choices never touch, whatever the language: with French names wider than the icon style's pitch,
    // the picker widens its pitch so each name keeps a gap from the next and stays centred under its own picture.
    Component {
        id: pickerComponent
        SettingsQml.ChoicePicker {
            model: [{id: "default", text: "Par défaut"}, {id: "dark", text: "Sombre"}, {id: "clear", text: "Transparent"}, {id: "tinted", text: "Teinté"}]
            value: "default"
            pictureWidth: Tokens.settingsIconStyleSize
            pictureHeight: Tokens.settingsIconStyleSize
            pitch: Tokens.settingsIconStylePitch
            ringGap: Tokens.settingsAccentRingGap
            captionBaseline: Tokens.settingsIconStyleCaptionBaseline
            picture: Component {
                Rectangle {
                    property string choice: ""
                }
            }
        }
    }

    function test_choiceNamesNeverTouch() {
        const picker = createTemporaryObject(pickerComponent, testCase);
        verify(picker);
        waitForRendering(picker);
        const names = picker.model.map(m => find(picker, i => i.text === m.text && i.visible && i.baselineOffset !== undefined));
        for (const n of names)
            verify(n);
        for (let i = 1; i < names.length; i++) {
            const a = names[i - 1].mapToItem(picker, 0, 0).x + names[i - 1].width;
            const b = names[i].mapToItem(picker, 0, 0).x;
            verify(b - a >= Tokens.settingsChoiceCaptionGap - 1, names[i].text + " starts " + (b - a) + " px after " + names[i - 1].text);
        }
        for (let i = 0; i < names.length; i++) {
            const c = names[i].mapToItem(picker, 0, 0).x + names[i].width / 2;
            const pic = picker.ringPad + i * picker.usedPitch + picker.pictureWidth / 2;
            verify(Math.abs(c - pic) <= 1, names[i].text + " is centred under its picture");
        }
    }

    // A choice row never overlaps its title (macOS): at Settings' minimum window width (its rows are 288 wide), in French as in
    // English, the icon styles sit beside the title when they fit and on their own line under it when they do not, never over
    // the title, never past the row, and no two names touch.
    function checkIconRow(title, names) {
        const t = make();
        const picker = named(t.page, "Icon style");
        verify(picker);
        const row = picker.parent;
        // The page width at which the group's rows are Settings' minimum 288 wide.
        const delta = row.width - t.page.width;
        t.page.width = 288 - delta;
        row.title = title;
        picker.model = names.map((n, i) => ({id: ["default", "dark", "clear", "tinted"][i], text: n}));
        waitForRendering(t.page);
        compare(row.width, 288);
        const label = find(row, i => i.text === title && i.baselineOffset !== undefined && i.visible && i !== picker);
        verify(label);
        const titleBox = label.mapToItem(row, 0, 0);
        const pictures = [];
        for (let i = 0; i < names.length; i++)
            pictures.push({x: picker.x + picker.ringPad + i * picker.usedPitch, y: picker.y + picker.ringPad, w: picker.pictureWidth, h: picker.pictureHeight});
        for (const p of pictures) {
            const apart = p.x >= titleBox.x + label.contentWidth || p.x + p.w <= titleBox.x || p.y >= titleBox.y + label.height || p.y + p.h <= titleBox.y;
            verify(apart, "a picture at " + p.x + "," + p.y + " overlaps the title " + titleBox.x + "," + titleBox.y + " " + label.contentWidth + "x" + label.height);
        }
        for (const n of names) {
            const c = find(picker, i => i.text === n && i.visible && i.baselineOffset !== undefined);
            verify(c);
            const box = c.mapToItem(row, 0, 0);
            verify(box.x >= 0 && box.x + c.width <= row.width, n + " is inside the row (" + box.x + " to " + (box.x + c.width) + ")");
        }
        verify(picker.x >= 0 && picker.x + picker.implicitWidth <= row.width, "the picker is inside the row");
        verify(row.height >= picker.y + picker.implicitHeight - picker.ringPad, "the row holds the picker");
        return row.stacked;
    }

    function test_iconRowAtMinimumWidthFrench() {
        verify(checkIconRow("Style des icônes", ["Par défaut", "Sombre", "Transparent", "Teinté"]), "French goes on its own line");
    }

    function test_iconRowAtMinimumWidthEnglish() {
        checkIconRow("Icon style", ["Default", "Dark", "Clear", "Tinted"]);
    }

    // The measured pitch holds when the names are short (English): the audit's 51.5.
    function test_choicePitchHoldsForShortNames() {
        const picker = createTemporaryObject(pickerComponent, testCase, {model: [{id: "default", text: "Default"}, {id: "dark", text: "Dark"}, {id: "clear", text: "Clear"}, {id: "tinted", text: "Tinted"}]});
        verify(picker);
        waitForRendering(picker);
        compare(picker.usedPitch, Tokens.settingsIconStylePitch);
    }
}
