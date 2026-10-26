pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.notifications
import "notifications/CenterLogic.js" as CenterLogic

// Clear model of the Notifications column on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_clear`,
// a dev session without the D-Bus server, state under GRASSFIELD_TEST_TMP; see the dev-session marker file).
// - a clear takes effect in the model at once (history, Center rows), with no animation to wait for;
// - a group clear acts on a snapshot of keys: an entry of the same app that arrives afterwards stays;
// - clearing a group twice works (no state is left behind);
// - the focus after a clear is chosen from the updated rows (CenterLogic.focusAfterGone): never another app's card while the app still has one;
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

    function shownRows(): var {
        const out = [];
        for (let i = 0; i < Notifications.centerModel.count; i++) {
            const r = Notifications.centerModel.get(i);
            out.push({key: r.key, appName: r.appName});
        }
        return out;
    }

    // What the focus resolver does for Delete on the card `key`: the card's group and rank and the settled rows first, the
    // clear, then the choice from the rows now (CenterLogic.focusAfterGone).
    function focusAfter(key: string, change: var): string {
        const before = shownRows();
        const at = before.findIndex(r => r.key === key);
        const app = before[at].appName;
        const rank = before.slice(0, at).filter(r => r.appName === app).length;
        change();
        return CenterLogic.focusAfterGone({key: key, app: app, rank: rank}, before.map(r => r.key), shownRows());
    }

    function deleteCard(key: string): string {
        return focusAfter(key, () => Notifications.clear(key));
    }

    function appOf(key: string): string {
        const e = Notifications.entryFor(key);
        return e ? e.appName : "";
    }

    function run(): void {
        // The scenes below were written for collapsed groups of three (the product shows one, a stack); the clear model does
        // not depend on the count.
        Notifications.groupCollapsed = 3;
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
        const head = Notifications.centerModel.get(0).key;
        const afterGroup = focusAfter(head, () => Notifications.clearKeys(Notifications.keysOf("mail")));
        check("group clear: next group's card", afterGroup === Notifications.centerModel.get(0).key && appOf(afterGroup) === "cal");
        check("last card of all: nothing to focus", deleteCard(Notifications.centerModel.get(0).key) === "" && Notifications.count === 0);

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
        Notifications.clearApp("app0");
        for (let g = 1; g < 10; g++)
            Notifications.clearApp("app" + g);
        check("everything cleared", Notifications.count === 0 && Notifications.centerModel.count === 0);

        // 7. "Show All" does not survive the group: once the group empties, its next notifications arrive collapsed.
        for (let i = 0; i < 6; i++)
            add("news");
        Notifications.setExpanded("news", true);
        check("expanded group shows all six", Notifications.centerModel.count === 6);
        Notifications.clearApp("news");
        check("expanded flag dropped with the group", Notifications.expandedApps.news === undefined);
        for (let i = 0; i < 6; i++)
            add("news");
        check("new cards of that app arrive collapsed", Notifications.centerModel.count === Notifications.groupCollapsed);
        // Clearing single cards down to one keeps the group (and its expansion) until it is empty.
        Notifications.setExpanded("news", true);
        const ks = Notifications.keysOf("news");
        for (let i = 0; i < ks.length - 1; i++)
            Notifications.clear(ks[i]);
        check("expansion kept while the group has a card", Notifications.expandedApps.news === true);
        Notifications.clear(ks[ks.length - 1]);
        check("expansion dropped with the last card", Notifications.expandedApps.news === undefined);

        // Same while another app keeps the Center non-empty (the group, not the whole column, empties).
        add("other");
        for (let i = 0; i < 6; i++)
            add("news");
        Notifications.setExpanded("news", true);
        check("expanded again", Notifications.expandedApps.news === true);
        Notifications.clearApp("news");
        check("expanded flag dropped with the group (other app present)", Notifications.expandedApps.news === undefined);
        for (let i = 0; i < 6; i++)
            add("news");
        check("collapsed again (other app present)", Notifications.keysOf("news").length === 6
            && Notifications.centerModel.count === Notifications.groupCollapsed + 1);
        Notifications.clearApp("news");
        Notifications.clearApp("other");

        // 8. Test-only IPC hooks follow the VisualFixtures gate (GRASSFIELD_DEV=1 and GRASSFIELD_VISUAL_FIXTURES=1, not a
        // packaged session). tests/shell/notif_hooks.sh runs this test in both modes (NOTIF_CLEAR_HOOKS=allowed|refused);
        // scripts/dev/test.sh runs it without the fixture flag: refused.
        const allowed = Quickshell.env("NOTIF_CLEAR_HOOKS") === "allowed";
        check("testHooks follows the gate", Notifications.testHooks === allowed);
        add("hook");
        const before = Notifications.count;
        const wiped = Notifications.hookClearAll();
        const dismissed = Notifications.hookDismissAll();
        const invoked = Notifications.hookInvoke("default");
        if (allowed) {
            check("clearAll hook works when allowed", wiped === "ok" && Notifications.count === 0);
            check("dismissAll hook works when allowed", dismissed === "ok");
            check("invoke hook works when allowed", invoked === "no live notification");
        } else {
            check("clearAll hook refused", wiped.startsWith("refused") && Notifications.count === before);
            check("dismissAll hook refused", dismissed.startsWith("refused"));
            check("invoke hook refused", invoked.startsWith("refused"));
        }
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
