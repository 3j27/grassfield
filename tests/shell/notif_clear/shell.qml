pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.notifications

// Clear model of the Notifications column on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_clear`,
// a dev session without the D-Bus server, state under GRASSFIELD_TEST_TMP; see the dev-session marker file).
// - a clear takes effect in the model at once (history, Center rows), with no animation to wait for;
// - a group clear acts on a snapshot of keys: an entry of the same app that arrives afterwards stays;
// - clearing a group twice works (no state is left behind);
// - the focus after a clear is read from the updated rows: never another app's card while the app still has one;
// - the model stays free of duplicated surfaces keys (rows are unique by key).
// Prints "notif-clear: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int seq: 0
    readonly property real base: Date.now()

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function add(app: string): string {
        seq++;
        const e = {
            key: "t-" + seq,
            nid: -1,
            appName: app,
            appIcon: "",
            image: "",
            summary: app + " " + seq,
            body: "",
            bodyHtml: "",
            time: base + seq,
            urgency: 1,
            transient: true,
            resident: false,
            actions: [],
            restored: false
        };
        Notifications.addEntry(e);
        return e.key;
    }

    function rows(): var {
        const out = [];
        for (let i = 0; i < Notifications.centerModel.count; i++) {
            const r = Notifications.centerModel.get(i);
            out.push(r.appName + ":" + r.key);
        }
        return out;
    }

    function slotOf(key: string): int {
        for (let i = 0; i < Notifications.centerModel.count; i++) {
            if (Notifications.centerModel.get(i).key === key)
                return i;
        }
        return -1;
    }

    // What the delegate does for Delete on the card `key`: the slot and app first, the clear, then the next focus.
    function deleteCard(key: string): string {
        const at = slotOf(key);
        const app = Notifications.centerModel.get(at).appName;
        Notifications.clear(key);
        return Notifications.focusKeyAfter(at, app);
    }

    function appOf(key: string): string {
        const e = Notifications.entryFor(key);
        return e ? e.appName : "";
    }

    function run(): void {
        // 1. Immediate clear: no event-loop turn between the clear and the model.
        const a = add("alpha");
        const b = add("alpha");
        add("beta");
        check("three entries", Notifications.count === 3);
        Notifications.clear(a);
        check("history updated at once", Notifications.count === 2 && Notifications.entryFor(a) === null);
        check("Center row removed at once", slotOf(a) < 0 && Notifications.centerModel.count === 2);
        Notifications.clear(b);
        Notifications.clearApp("beta");
        check("last card: history empty", Notifications.count === 0 && Notifications.centerModel.count === 0);

        // 2. Snapshot clear.
        for (let i = 0; i < 5; i++)
            add("mail");
        const snap = Notifications.keysOf("mail");
        check("snapshot has the five", snap.length === 5);
        const late = add("mail");
        Notifications.clearKeys(snap);
        check("snapshot clear keeps the later arrival", Notifications.count === 1 && Notifications.entryFor(late) !== null);
        check("later arrival still shown", slotOf(late) === 0);
        // Twice in a row: nothing stays stuck after a group clear.
        for (let i = 0; i < 4; i++)
            add("mail");
        Notifications.clearApp("mail");
        check("second group clear works", Notifications.count === 0);

        // 3. Focus after a Delete, collapsed group (3 shown: the others are revealed one by one).
        add("cal");
        const mailKeys = [];
        for (let i = 0; i < 6; i++)
            mailKeys.push(add("mail"));
        // rows: mail x3 (newest first), cal
        check("collapsed rows", rows().length === 4 && rows()[3].startsWith("cal:"));
        const third = Notifications.centerModel.get(2).key;
        const next1 = deleteCard(third);
        check("revealed card takes the slot", slotOf(next1) === 2 && appOf(next1) === "mail");
        check("focus is not on cal after the first Delete", appOf(next1) === "mail");
        const next2 = deleteCard(next1);
        check("second Delete again stays in the group", appOf(next2) === "mail" && slotOf(next2) === 2);
        check("cal untouched after two Deletes", Notifications.entryFor(rows()[rows().length - 1].split(":")[1]).appName === "cal"
            && Notifications.keysOf("cal").length === 1);
        check("four mails left", Notifications.keysOf("mail").length === 4);

        // 4. Expanded group: Delete the last card, focus the group's new last card.
        Notifications.setExpanded("mail", true);
        const all = rows();
        check("expanded rows", all.length === 5);
        const lastMail = Notifications.centerModel.get(3).key;
        const prev = deleteCard(lastMail);
        check("expanded: previous card of the group", appOf(prev) === "mail" && slotOf(prev) === 2);
        // first card of the group
        const firstMail = Notifications.centerModel.get(0).key;
        const nextFirst = deleteCard(firstMail);
        check("expanded: first card, the next one of the group", appOf(nextFirst) === "mail" && slotOf(nextFirst) === 0);

        // 5. Group clear: the focus goes to the next group, else the previous.
        const at = 0;
        Notifications.clearKeys(Notifications.keysOf("mail"));
        check("group clear: next group's card", Notifications.focusKeyAfter(at, "mail") === Notifications.centerModel.get(0).key
            && appOf(Notifications.focusKeyAfter(at, "mail")) === "cal");
        Notifications.clear(Notifications.centerModel.get(0).key);
        check("last card of all: nothing to focus", Notifications.focusKeyAfter(0, "cal") === "" && Notifications.count === 0);

        // 6. Many entries and groups: unique row keys, a group clear is one model change.
        for (let g = 0; g < 10; g++) {
            for (let i = 0; i < 10; i++)
                add("app" + g);
        }
        check("100 entries", Notifications.count === 100);
        const seen = {};
        let dup = false;
        for (const r of rows()) {
            const k = r.split(":")[1];
            dup = dup || seen[k] === true;
            seen[k] = true;
        }
        check("row keys unique", !dup);
        Notifications.clearKeys(Notifications.keysOf("app3"));
        check("one group of ten cleared", Notifications.count === 90 && Notifications.keysOf("app3").length === 0);
    }

    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (!Notifications.historyReady)
                return;
            running = false;
            root.run();
            if (root.failures.length === 0) {
                console.log("notif-clear: PASS");
                Qt.exit(0);
            } else {
                console.log("notif-clear: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 10000
        running: true
        onTriggered: {
            console.log("notif-clear: FAIL history never became ready (serverState " + Notifications.serverState + ")");
            Qt.exit(1);
        }
    }
}
