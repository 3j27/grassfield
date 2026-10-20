pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Notifications
import qs.notifications

// Random-sequence test of the focus invariant of the Notifications column: the REAL list (shell/notifications/NotificationList.qml)
// on the real Notifications singleton (scripts/dev/test.sh, offscreen, dev session; see tests/shell/notif_center_list for the
// plain-window setup). Seeded turns of 1 to 4 changes each (arrivals, app closes, expiries, same-id updates that add or drop
// actions, x clicks, Clear All, Show All / Show Less, More) with the focus anywhere (every card and control, or outside the
// cards) and real key events (Space, Return, Enter, Delete, Backspace, Tab, Shift+Tab; the last two through tabStep as the
// column's shortcuts do), before and after the changes of the turn. After EVERY turn the active focus is on the element named
// by the identity (visible, enabled, displayed), or on the panel when no card is left, or still where it was put outside the
// cards. Prints "notif-center-random: PASS" or the violations (count and the first turns).
ShellRoot {
    id: root

    property var failures: []
    property int seq: 0
    readonly property real base: Date.now()
    property var steps: []
    property int stepAt: 0
    readonly property alias list: list

    // Stands in for the column (CenterContent): the surface host the list talks to.
    QtObject {
        id: hostStub

        property string hoverApp: ""

        function addSurface(item: var, clip: bool, radius: real, fader: var): void {
        }

        function hoverCard(app: string, over: bool): void {
        }
    }

    Window {
        id: win

        visible: true
        width: 500
        height: 1100

        FocusScope {
            id: panel

            readonly property int gutter: 12

            anchors.fill: parent
            focus: true

            NotificationList {
                id: list

                x: -panel.gutter
                y: -panel.gutter
                width: parent.width + panel.gutter
                height: parent.height - 200
                host: hostStub
                panel: panel
                editTarget: editStub
                closeTarget: closeStub
            }

            Item {
                id: editStub

                y: parent.height - 100
                width: 60
                height: 30
                activeFocusOnTab: true
            }

            Item {
                id: closeStub

                x: 100
                y: parent.height - 100
                width: 30
                height: 30
                activeFocusOnTab: true
            }
        }
    }

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    // Real key events to the window's focus item.
    TestCase {
        id: keys

        name: "keys"
        when: false
    }

    function add(app: string, extra: var): string {
        seq++;
        const e = Object.assign({
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
        }, extra ? extra : {});
        Notifications.addEntry(e);
        return e.key;
    }

    // The delegate showing `key` (not one that is leaving), or null.
    function card(key: string): Item {
        for (let i = 0; i < list.count; i++) {
            const it = list.itemAtIndex(i);
            if (it && it.key === key && !it.removing)
                return it;
        }
        return null;
    }

    function shownKeys(): var {
        const out = [];
        for (let i = 0; i < Notifications.centerModel.count; i++)
            out.push(Notifications.centerModel.get(i).key);
        return out;
    }

    // Key of the card that holds the keyboard focus ("" when none).
    function held(): string {
        const d = list.focusedDelegate();
        return d ? d.key : "";
    }

    function focusCard(key: string): bool {
        const c = root.card(key);
        if (!c)
            return false;
        c.rowItem.forceActiveFocus();
        return root.held() === key;
    }

    // Focus is on a card that is displayed, enabled and not leaving.
    function focusIsLive(): bool {
        const d = list.focusedDelegate();
        return d !== null && !d.removing && d.enabled && root.shownKeys().indexOf(d.key) >= 0;
    }

    // The usable control `role` of the card `key` (null when it does not exist or is hidden).
    function ctl(key: string, role: string): Item {
        const d = list.delegateFor(key, false);
        return d ? list.controlOf(d, role) : null;
    }

    function focusCtl(key: string, role: string): bool {
        const c = root.ctl(key, role);
        if (!c)
            return false;
        c.forceActiveFocus();
        return win.activeFocusItem === c;
    }

    function ident(): var {
        return list.identityOf(win.activeFocusItem);
    }

    // The focus is on a card or a control of a card that exists, is visible and enabled, and is displayed.
    function onUsable(): bool {
        const f = win.activeFocusItem;
        const id = list.identityOf(f);
        return id !== null && list.itemOf(id) === f && f.visible && f.enabled && root.shownKeys().indexOf(id.key) >= 0;
    }

    // No hidden or disabled control of a displayed card holds the focus.
    function noHiddenFocus(): bool {
        for (let i = 0; i < list.count; i++) {
            const d = list.itemAtIndex(i);
            if (!d || d.removing)
                continue;
            for (const c of d.controls()) {
                if (!list.usable(c.item) && c.item.activeFocus)
                    return false;
            }
        }
        return true;
    }

    // Keys of the displayed cards of an app, top to bottom.
    function shownOf(app: string): var {
        return Notifications.centerModel.count === 0 ? [] : root.shownKeys().filter(k => {
            const e = Notifications.entryFor(k);
            return e !== null && e.appName === app;
        });
    }

    // Every usable focus target of the column right now: [{item}] of cards and controls.
    function targets(): var {
        const out = [];
        for (let i = 0; i < list.count; i++) {
            const d = list.itemAtIndex(i);
            if (!d || d.removing)
                continue;
            for (const c of d.controls()) {
                if (list.usable(c.item))
                    out.push(c.item);
            }
        }
        return out;
    }

    // The focus is on the column's panel.
    function atPanel(): bool {
        return win.activeFocusItem === panel;
    }

    function resetAll(): void {
        Notifications.clearKeys(Notifications.history.map(e => e.key));
        Notifications.centerOpen = true;
        list.releaseFocus();
    }

    // A scene: reset, build, act (the focus is set and the change made in ONE event-loop turn), check.
    function scene(build, act, verify): void {
        const s = {};
        step(() => root.resetAll(), 350);
        step(() => build(s), 350);
        step(() => act(s), 200);
        step(() => verify(s), 50);
    }

    // Every non-leaving delegate sits right under the one above it and carries no visual offset left.
    function layoutOk(): bool {
        let prev = null;
        for (let i = 0; i < list.count; i++) {
            const d = list.itemAtIndex(i);
            if (!d || d.removing)
                return false;
            if (Math.abs(d.shift) > 0.01 || Math.abs(d.slide) > 0.01 || d.opacity < 0.999)
                return false;
            if (prev && Math.abs(d.y - (prev.y + prev.height)) > 0.5)
                return false;
            prev = d;
        }
        return true;
    }

    function step(fn, ms: int): void {
        steps.push({fn: fn, ms: ms});
    }

    // ---- the random turns ----
    property var st: ({bad: 0, log: [], desc: "", turns: 0, inList: 0, moved: 0, keys: 0, prevActive: null, outside: null, checked: false})

    function press(code: int): void {
        root.st.keys++;
        if (code === Qt.Key_Tab)
            list.tabStep(true);
        else if (code === Qt.Key_Backtab)
            list.tabStep(false);
        else
            keys.keyClick(code);
    }

    // Where the focus stands once the keys and the changes of the turn are in, before the resolver ran: in the cards or not.
    function snapshotFocus(): void {
        const P = root.st;
        const f = win.activeFocusItem;
        // Outside the cards: Edit Widgets, the close circle, or the panel after the resolver released an empty column.
        P.outside = f === editStub || f === closeStub || (root.atPanel() && list.focusId === null) ? f : null;
        P.prevActive = win.activeFocusItem;
    }

    // The invariant, after the resolver ran.
    function verifyTurn(): void {
        const P = root.st;
        if (!P.checked)
            return;
        P.checked = false;
        P.turns++;
        let ok;
        let why = "";
        if (P.outside !== null) {
            ok = win.activeFocusItem === P.outside;
            why = "outside focus moved";
        } else {
            P.inList++;
            if (win.activeFocusItem !== P.prevActive)
                P.moved++;
            if (Notifications.centerModel.count === 0) {
                ok = root.atPanel();
                why = "no card left, focus not on the panel";
            } else {
                ok = root.onUsable();
                why = "focus not on a usable element";
                if (ok) {
                    ok = list.focusId !== null && list.itemOf(list.focusId) === win.activeFocusItem;
                    why = "identity does not name the focused item";
                }
            }
        }
        if (ok && !root.noHiddenFocus()) {
            ok = false;
            why = "a hidden control holds the focus";
        }
        if (!ok) {
            P.bad++;
            if (P.log.length < 5)
                P.log.push(P.desc + " => " + why + " f=" + win.activeFocusItem + " id=" + JSON.stringify(root.ident()));
        }
    }

    function liveDelegates(): var {
        const out = [];
        for (let i = 0; i < list.count; i++) {
            const d = list.itemAtIndex(i);
            if (d && !d.removing)
                out.push(d);
        }
        return out;
    }

    function run(): void {
        const CLOSED = NotificationCloseReason.CloseRequested;
        const apps = ["mail", "cal", "chat"];
        const ids = ["a", "b", "c", "d", "e"];
        const codes = [Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter, Qt.Key_Delete, Qt.Key_Backspace, Qt.Key_Tab, Qt.Key_Backtab];
        const codeNames = ["Space", "Return", "Enter", "Delete", "Backspace", "Tab", "Shift+Tab"];
        const seeds = [20261020, 77, 424242];
        const turnsPerSeed = 180;
        let state = 1;
        const rnd = n => {
            state = (state * 1103515245 + 12345) % 2147483648;
            return Math.floor(state / 65536) % n;
        };
        const actionsOf = n => ids.slice(0, n).map(a => ({id: a, text: "Do " + a}));
        const P = root.st;

        for (const seed of seeds) {
            step(() => {
                root.verifyTurn();
                state = seed;
                root.resetAll();
            }, 350);
            for (let t = 0; t < turnsPerSeed; t++) {
                step(() => {
                    root.verifyTurn();
                    Notifications.centerOpen = true;
                    const desc = [];
                    // The focus first: any card control, outside the cards, or (rarely) nothing placed.
                    const all = root.targets();
                    const pick = rnd(all.length + 2);
                    if (pick < all.length)
                        all[pick].forceActiveFocus();
                    else if (pick === all.length)
                        editStub.forceActiveFocus();
                    else
                        closeStub.forceActiveFocus();
                    desc.push("focus " + (pick < all.length ? (root.ident() ? root.ident().role : "?") : "outside"));
                    // Keys on the settled state.
                    if (rnd(10) < 5) {
                        const k = rnd(codes.length);
                        root.press(codes[k]);
                        desc.push("key " + codeNames[k]);
                    }
                    // 1 to 4 changes in one turn.
                    const n = 1 + rnd(4);
                    for (let i = 0; i < n; i++) {
                        const mine = Notifications.history;
                        const op = rnd(11);
                        const app = apps[rnd(apps.length)];
                        const ds = root.liveDelegates();
                        const d = ds.length > 0 ? ds[rnd(ds.length)] : null;
                        if (op <= 2 || mine.length === 0) {
                            const live = rnd(2) === 0;
                            root.add(app, live ? {nid: 1000 + root.seq, actions: actionsOf(rnd(6))} : {});
                            desc.push("arrive:" + app + (live ? "+act" : ""));
                        } else if (op === 3) {
                            Notifications.closed(mine[rnd(mine.length)].key, CLOSED);
                            desc.push("close");
                        } else if (op === 4) {
                            Notifications.closed(mine[rnd(mine.length)].key, NotificationCloseReason.Expired);
                            desc.push("expire");
                        } else if (op === 5 || op === 6) {
                            const lives = mine.filter(e => e.nid >= 0);
                            if (lives.length > 0) {
                                const e = lives[rnd(lives.length)];
                                Notifications.updateEntry(e.key, Object.assign({}, e, {actions: actionsOf(rnd(6))}));
                                desc.push("update");
                            }
                        } else if (op === 7 && d) {
                            d.clearCard(false, false);
                            desc.push("x");
                        } else if (op === 8 && d) {
                            const g = ds.filter(x => root.ctl(x.key, "clearGroup") !== null);
                            if (g.length > 0) {
                                const x = g[rnd(g.length)];
                                x.clearCard(true, false);
                                desc.push("clearAll");
                            }
                        } else if (op === 9 && d) {
                            const g = ds.filter(x => root.ctl(x.key, "showAll") !== null || root.ctl(x.key, "showLess") !== null);
                            if (g.length > 0) {
                                const x = g[rnd(g.length)];
                                const c = root.ctl(x.key, "showAll") || root.ctl(x.key, "showLess");
                                c.clicked();
                                desc.push("showAllLess");
                            }
                        } else if (op === 10 && d) {
                            const g = ds.filter(x => root.ctl(x.key, "more") !== null);
                            if (g.length > 0) {
                                root.ctl(g[rnd(g.length)].key, "more").clicked();
                                desc.push("more");
                            }
                        }
                    }
                    // Keys again, before the resolver of this turn ran: they meet the state the changes left.
                    if (rnd(10) < 5) {
                        const k = rnd(codes.length);
                        root.press(codes[k]);
                        desc.push("key " + codeNames[k]);
                    }
                    P.desc = "seed " + seed + " turn " + t + ": " + desc.join(", ");
                    root.snapshotFocus();
                    P.checked = true;
                }, 28);
            }
        }
        step(() => {
            root.verifyTurn();
            console.log("notif-center-random: " + P.turns + " turns, " + P.inList + " with the focus in the cards, focus moved " + P.moved + ", keys " + P.keys + ", violations " + P.bad);
            root.check("every random turn kept the invariant (" + P.bad + " violations): " + P.log.join(" | "), P.bad === 0);
            root.check("at least 500 turns ran", P.turns >= 500);
            root.check("the focus really moved in the random turns", P.moved >= 50);
        }, 5);
    }

    Timer {
        id: runner

        running: false
        repeat: false
        onTriggered: {
            if (root.stepAt >= root.steps.length) {
                if (root.failures.length === 0) {
                    console.log("notif-center-random: PASS");
                    Qt.exit(0);
                } else {
                    console.log("notif-center-random: FAIL " + root.failures.join(", "));
                    Qt.exit(1);
                }
                return;
            }
            const s = root.steps[root.stepAt++];
            s.fn();
            runner.interval = s.ms;
            runner.restart();
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
            runner.interval = 1;
            runner.start();
        }
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("notif-center-random: FAIL timeout at step " + root.stepAt + " " + root.failures.join(", "));
            Qt.exit(1);
        }
    }
}
