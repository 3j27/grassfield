import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Lock Screen as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Lock Screen): the display-off
// pop-ups (the battery one only with a battery), the password delay, what the lock screen shows, and the message sheet that
// refuses anything but one line of plain text. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsLock"
    width: 508
    height: 900
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
        id: pageComponent
        SettingsQml.LockPage {
            width: 508
            height: 900
        }
    }

    Component {
        id: sheetComponent
        SettingsQml.LockMessageSheet {
            anchors.fill: parent
        }
    }

    function make(battery) {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store, hasBattery: battery === true});
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

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_displayOff() {
        const t = make(true);
        const battery = named(t.page.contentItem, "Turn display off on battery when inactive");
        verify(battery.inline);
        compare(battery.value, "2");
        compare(battery.model.find(m => m.id === "2").text, "For 2 minutes");
        compare(battery.model.find(m => m.id === "60").text, "For 1 hour");
        compare(battery.model[0].text, "Never");
        battery.picked("0");
        compare(last(t.store), {"lock.displayOffBattery": 0});
        const power = named(t.page.contentItem, "Turn display off on power adapter when inactive");
        compare(power.value, "10");
        power.picked("30");
        compare(last(t.store), {"lock.displayOffPower": 30});
    }

    function test_withoutBattery() {
        const t = make(false);
        const battery = named(t.page.contentItem, "Turn display off on battery when inactive");
        verify(!battery.parent.parent.visible);
        verify(named(t.page.contentItem, "Turn display off when inactive"));
    }

    // A computer without a battery (the owner's report of rc1-22: a desktop PC): "Turn display off when inactive" offers Never,
    // first as on macOS, and picking it writes 0 (the shell never turns the displays off for inactivity then).
    function test_withoutBatteryOffersNever() {
        const t = make(false);
        const power = named(t.page.contentItem, "Turn display off when inactive");
        verify(power && power.visible);
        compare(power.model[0], {id: "0", text: "Never"});
        power.picked("0");
        compare(last(t.store), {"lock.displayOffPower": 0});
        compare(power.value, "0");
        compare(power.model.filter(m => m.id === "0").length, 1, "Never once");
    }

    function test_requirePassword() {
        const t = make();
        const delay = named(t.page.contentItem, "Require password after inactivity");
        compare(delay.value, "5");
        compare(delay.model.find(m => m.id === "5").text, "After 5 minutes");
        delay.picked("15");
        compare(last(t.store), {"lock.idleMinutes": 15});
        // A hand-edited value stays selectable.
        t.store.set("lock.idleMinutes", 7);
        compare(delay.model.find(m => m.id === "7").text, "After 7 minutes");
    }

    // A dark display is not a locked one: the note under the delays says so when a display turns off before the session locks.
    // ADR-0040 IQ-T4 A: the display-off lock (macOS's Require password after the display is turned off), Immediately by
    // default, and the note that follows it.
    function test_requirePasswordAfterDisplayOff() {
        const t = make(true);
        const note = () => find(t.page.contentItem, i => i.footnote !== undefined && i.footnote !== "" && i.visible).footnote;
        const pop = find(t.page.contentItem, i => i.accessibleName === "Require password after the display turns off" && i.picked !== undefined);
        verify(pop);
        compare(pop.model.map(m => m.id), ["immediately", "5s", "1m", "5m", "15m", "1h", "never"]);
        compare(pop.value, "immediately");
        compare(note(), "The session locks after this much time without keyboard or pointer input, or as soon as a display turns off.");
        pop.picked("5m");
        compare(last(t.store), {"lock.requirePasswordAfterDisplayOff": "5m"});
        verify(note().indexOf("once a display has been off for the time set below") >= 0, note());
        t.store.set("lock.idleMinutes", 0);
        verify(note().indexOf("locks when a display turns off") >= 0, note());
        // Displays that never turn off: the display-off lock has nothing to follow.
        t.store.set("lock.displayOffBattery", 0);
        t.store.set("lock.displayOffPower", 0);
        verify(note().indexOf("does not lock by itself") >= 0, note());
    }

    function test_lockNote() {
        const t = make(true);
        // The notes of a display that does not lock the session ("Never").
        t.store.set("lock.requirePasswordAfterDisplayOff", "never");
        const note = () => find(t.page.contentItem, i => i.footnote !== undefined && i.footnote !== "" && i.visible).footnote;
        // The defaults: off at 2 minutes on battery, locked at 5.
        verify(t.page.offFirst);
        verify(note().indexOf("A display that turns off earlier is not locked") >= 0, note());
        t.store.set("lock.displayOffBattery", 10);
        verify(!t.page.offFirst, "power 10, battery 10, lock 5");
        compare(note(), "The session locks after this much time without keyboard or pointer input, whether the displays are on or off.");
        t.store.set("lock.displayOffPower", 3);
        verify(t.page.offFirst, "on the power adapter too");
        t.store.set("lock.displayOffPower", 0);
        verify(!t.page.offFirst, "a display that never turns off");
        t.store.set("lock.idleMinutes", 0);
        verify(note().indexOf("does not lock by itself") >= 0, note());
        // Without a battery, the battery's delay does not count.
        const desk = make(false);
        desk.store.set("lock.requirePasswordAfterDisplayOff", "never");
        desk.store.set("lock.displayOffPower", 10);
        verify(!desk.page.offFirst, "battery 2 does not apply");
    }

    function test_whatTheLockScreenShows() {
        const t = make();
        const user = named(t.page.contentItem, "Show user name and photo");
        verify(user.checked);
        user.toggled(false);
        compare(last(t.store), {"lock.showUser": false});
        const set = find(t.page.contentItem, i => i.text === "Set…" && i.clicked !== undefined);
        verify(!set.enabled, "Set… is dimmed while the message is off");
        let asked = 0;
        t.page.messageRequested.connect(() => asked++);
        // Turned on without a message: the sheet is asked for.
        named(t.page.contentItem, "Show message when locked").toggled(true);
        compare(last(t.store), {"lock.showMessage": true});
        compare(asked, 1);
        verify(set.enabled);
        set.clicked();
        compare(asked, 2);
    }

    function test_messageSheet() {
        const t = make();
        const sheet = createTemporaryObject(sheetComponent, testCase, {store: t.store});
        t.store.set("lock.message", "Back at 3");
        sheet.open();
        compare(sheet.fieldText, "Back at 3");
        sheet.setField("  Gone fishing  ");
        sheet.confirm();
        compare(last(t.store), {"lock.message": "Gone fishing"});
        verify(!sheet.visible);
        // Two lines or too long: refused, the sheet stays open with its error.
        sheet.open();
        const writes = t.store.writes.length;
        sheet.setField("x".repeat(201));
        sheet.confirm();
        verify(sheet.visible);
        verify(sheet.errorText !== "");
        compare(t.store.writes.length, writes);
        sheet.cancel();
        compare(t.store.value("lock.message"), "Gone fishing");
    }
}
