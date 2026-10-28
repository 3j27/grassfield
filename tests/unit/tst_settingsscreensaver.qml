import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Wallpaper > Screen Saver… (ADR-0032): the four savers, the delay pop-up, the slideshow's folder row, and the note
// when the session locks or the display turns off first. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsScreenSaver"
    width: 600
    height: 700
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function setMany(entries: var): bool {
                writes.push(entries);
                values = Object.assign({}, values, entries);
                return true;
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                return setMany(e);
            }
        }
    }

    Component {
        id: sheetComponent
        SettingsQml.ScreenSaverSheet {
            anchors.fill: parent
        }
    }

    function make(battery) {
        const store = createTemporaryObject(storeComponent, testCase);
        const sheet = createTemporaryObject(sheetComponent, testCase, {store: store, hasBattery: battery === true});
        verify(sheet);
        sheet.open();
        return {store: store, sheet: sheet};
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

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_savers() {
        const t = make();
        const picker = named(t.sheet, "Screen saver");
        compare(picker.model.map(m => m.id), ["artwork", "wallpaperClock", "slideshow", "clock"]);
        compare(picker.value, "artwork");
        picker.picked("clock");
        compare(last(t.store), {"screensaver.kind": "clock"});
    }

    function test_delay() {
        const t = make();
        const delay = named(t.sheet, "Start screen saver when inactive");
        verify(delay.inline);
        compare(delay.value, "0");
        compare(delay.model[0].text, "Never");
        compare(delay.model.find(m => m.id === "20").text, "For 20 minutes");
        compare(delay.model.find(m => m.id === "60").text, "For 1 hour");
        delay.picked("5");
        compare(last(t.store), {"screensaver.idleMinutes": 5});
        // A hand-edited delay stays selectable.
        t.store.set("screensaver.idleMinutes", 7);
        compare(delay.model.find(m => m.id === "7").text, "For 7 minutes");
    }

    // The folder row only for the slideshow; empty is the Pictures folder.
    function test_slideshowFolder() {
        const t = make();
        const folderLabel = () => find(t.sheet, i => i.text === "Pictures folder" || i.text === "Photos");
        const row = () => folderLabel().parent.parent;
        verify(!row().visible);
        t.store.set("screensaver.kind", "slideshow");
        verify(row().visible);
        compare(folderLabel().text, "Pictures folder");
        t.store.set("screensaver.folder", "/home/u/Photos");
        compare(folderLabel().text, "Photos");
    }

    // macOS's note: the session locks, or the display turns off, before the saver would start.
    function test_timingNote() {
        const t = make(true);
        compare(t.sheet.timingNote, "", "never: no note");
        t.store.setMany({"screensaver.idleMinutes": 10, "lock.idleMinutes": 5});
        verify(t.sheet.timingNote.indexOf("locks") >= 0);
        t.store.setMany({"lock.idleMinutes": 30, "lock.displayOffPower": 15, "lock.displayOffBattery": 2});
        verify(t.sheet.timingNote.indexOf("turns off") >= 0, "on battery the display goes off at 2 minutes");
        t.store.setMany({"lock.displayOffBattery": 0, "lock.displayOffPower": 0});
        compare(t.sheet.timingNote, "");
        let asked = 0;
        t.sheet.lockScreenRequested.connect(() => asked++);
        t.store.set("lock.idleMinutes", 10);
        const button = find(t.sheet, i => i.text === "Lock Screen Settings…" && i.clicked !== undefined);
        verify(button.visible);
        button.clicked();
        compare(asked, 1);
    }

    // Without a battery only the power adapter's delay counts.
    function test_withoutBattery() {
        const t = make(false);
        t.store.setMany({"screensaver.idleMinutes": 10, "lock.idleMinutes": 0, "lock.displayOffPower": 0, "lock.displayOffBattery": 2});
        compare(t.sheet.timingNote, "");
    }
}
