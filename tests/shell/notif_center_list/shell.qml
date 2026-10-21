pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Notifications
import qs.notifications

// The REAL list of the Notifications column (shell/notifications/NotificationList.qml, the component NotificationCenter
// uses) on the real Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_center_list`, offscreen, a dev
// session without the D-Bus server; see the dev-session marker file). It sits in a plain window: the PanelWindow needs a
// Wayland compositor, so the column itself is covered by the nested checks (tests/shell/notif_clear/nested.sh).
//  - focus never stays on a hidden, disabled or removed card (arrival pushing it out of a collapsed group, Show Less, a
//    collapse on the 5th or last card, an expiry or removal, a group clear, the last card);
//  - a same-id update by the app keeps the focus where it is;
//  - tabStep: Tab and Shift+Tab in visual order, also after arrivals (creation order differs); focusedDelegate;
//  - clearCard refocus (accessibility path); Show All / Show Less hand the focus to the other control;
//  - the layout converges to the model layout after toggles (no stale offset), also when toggled mid-animation;
//  - the focus invariant (NotificationList.resolveFocus): a focused CONTROL that gets hidden (Clear All after an arrival or after
//    the app closes the other card, Show Less, Show All, More, the sender's actions), several changes in one event-loop turn,
//    the expiry of the focused card: the focus lands on a visible, enabled element and Return acts on that; keys never act on a
//    hidden control; a seeded random sequence of arrivals, closes, expiries, toggles and clears with the focus anywhere;
//  - bumpTick coalesces a frame's bumps; takeFresh animates an arrival once and never a card that is merely revealed.
// Prints "notif-center-list: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int seq: 0
    readonly property real base: Date.now()
    property var steps: []
    property int stepAt: 0
    property int escapes: 0
    property var fired: []
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
            Keys.onEscapePressed: root.escapes++

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
    function scene(build, act, verify, final): void {
        const s = {};
        step(() => root.resetAll(), 350);
        step(() => build(s), 350);
        step(() => act(s), 200);
        step(() => verify(s), final ? 250 : 50);
        if (final)
            step(() => final(s), 50);
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

    function run(): void {
        // 0. Three mail cards displayed (m5 m4 m3, m2 m1 hidden), then the calendar card.
        let k = {};
        step(() => {
            Notifications.centerOpen = true;
            win.requestActivate();
            k.cal = root.add("cal");
            for (let i = 1; i <= 5; i++)
                k["m" + i] = root.add("mail");
        }, 700);
        step(() => {
            root.check("setup: window active", win.active);
            root.check("setup: four cards displayed", Notifications.centerModel.count === 4 && list.count === 4);
            root.check("setup: shown order", root.shownKeys().join() === [k.m5, k.m4, k.m3, k.cal].join());
            root.check("setup: layout settled", root.layoutOk());
            // focusedDelegate: null while the focus is on the panel, the card while it is on the card or its x.
            list.releaseFocus();
            root.check("focusedDelegate: none on the panel", list.focusedDelegate() === null);
            root.check("focus card", root.focusCard(k.m4));
            list.tabStep(true);
            root.check("focusedDelegate: card or its x", root.held() === k.m4 && root.card(k.m4).rowItem.activeFocus === false);
            root.check("tracked identity follows the focus", list.focusId !== null && list.focusId.key === k.m4 && list.focusId.role === "close");
        }, 50);

        // 1. An arrival pushes the focused 3rd card out of the collapsed group: focus goes to the card in its slot.
        step(() => {
            root.check("1: focus 3rd card", root.focusCard(k.m3));
            k.m6 = root.add("mail");
        }, 250);
        step(() => {
            root.check("1: m3 left the rows", root.shownKeys().indexOf(k.m3) < 0);
            root.check("1: focus is on a live card", root.focusIsLive());
            root.check("1: focus is on the card now in that slot (m4)", root.held() === k.m4);
            root.check("1: tracked identity", list.focusId !== null && list.focusId.key === k.m4);
        }, 50);

        // 2. Show Less hides the focused 5th card (expanded group m6 m5 m4 m3 m2 m1).
        step(() => {
            Notifications.setExpanded("mail", true);
        }, 300);
        step(() => {
            root.check("2: expanded shows six", Notifications.centerModel.count === 7);
            root.check("2: focus 5th card", root.focusCard(k.m2));
            Notifications.setExpanded("mail", false);
        }, 250);
        step(() => {
            root.check("2: Show Less: focus on the group's last displayed card", root.held() === k.m4 && root.focusIsLive());
        }, 50);

        // 3. Collapse while the focus is on the last card (6th).
        step(() => {
            Notifications.setExpanded("mail", true);
        }, 300);
        step(() => {
            root.check("3: focus 6th card", root.focusCard(k.m1));
            Notifications.setExpanded("mail", false);
        }, 250);
        step(() => {
            root.check("3: collapse: focus on the last displayed card", root.held() === k.m4 && root.focusIsLive());
        }, 50);

        // 4. The focused notification expires (the app closes it): the card revealed in its slot takes the focus.
        step(() => {
            root.check("4: focus 3rd card (m4)", root.focusCard(k.m4));
            Notifications.closed(k.m4, NotificationCloseReason.CloseRequested);
        }, 250);
        step(() => {
            root.check("4: m4 is gone", Notifications.entryFor(k.m4) === null && root.shownKeys().indexOf(k.m4) < 0);
            root.check("4: the revealed card (m3) has the focus", root.held() === k.m3 && root.focusIsLive());
        }, 50);

        // 5. The app replaces the focused notification (same id): same card, same focus, new text.
        step(() => {
            root.check("5: focus 2nd card", root.focusCard(k.m5));
            const e = Notifications.entryFor(k.m5);
            Notifications.updateEntry(k.m5, Object.assign({}, e, {summary: "replaced"}));
        }, 250);
        step(() => {
            root.check("5: focus stays", root.held() === k.m5 && root.focusIsLive());
            root.check("5: text updated", root.card(k.m5).summary === "replaced");
        }, 50);

        // 6. Delete (clearCard with refocus) on the top card moves the focus to the one that moved up.
        step(() => {
            root.check("6: focus top card", root.focusCard(k.m6));
            root.card(k.m6).clearCard(false, true);
        }, 250);
        step(() => {
            root.check("6: next card has the focus", root.held() === k.m5 && root.focusIsLive());
        }, 50);

        // 7. Accessibility path: the focus is elsewhere, the card is cleared with refocus: focus lands on a card.
        step(() => {
            list.releaseFocus();
            root.card(k.m5).clearCard(false, true);
        }, 250);
        step(() => {
            root.check("7: refocus without prior focus", root.held() !== "" && root.focusIsLive());
        }, 50);

        // 8. Tab order, also after arrivals (the creation order is no longer the visual order).
        step(() => {
            k.m7 = root.add("mail");
            k.o1 = root.add("other");
        }, 400);
        step(() => {
            const keys = root.shownKeys();
            root.focusCard(keys[0]);
            const seen = [];
            let lastRegion = 0;
            let monotonic = true;
            let sawEdit = false;
            let sawClose = false;
            for (let i = 0; i < 40 && !sawClose; i++) {
                list.tabStep(true);
                const f = win.activeFocusItem;
                if (f === editStub)
                    sawEdit = true;
                else if (f === closeStub)
                    sawClose = true;
                else {
                    const r = list.regionOf(f);
                    monotonic = monotonic && r >= lastRegion;
                    lastRegion = r;
                    if (seen.indexOf(r) < 0)
                        seen.push(r);
                }
            }
            root.check("8: Tab visits every card in visual order", monotonic && seen.join() === keys.map((_, i) => i).join());
            root.check("8: Tab reaches Edit Widgets then the close circle", sawEdit && sawClose);
            list.tabStep(true);
            root.check("8: Tab from the close circle wraps to the top card", root.held() === keys[0]);
            list.tabStep(false);
            root.check("8: Shift+Tab from the top card goes backwards to the close circle", win.activeFocusItem !== null && root.held() === "");
            const back = [];
            for (let i = 0; i < 40; i++) {
                list.tabStep(false);
                const f = win.activeFocusItem;
                const r = f === editStub ? -1 : list.regionOf(f);
                if (r >= 0 && back.length === 0 || r >= 0 && back[back.length - 1] !== r)
                    back.push(r);
                if (r === 0 && i > 0 && root.held() === keys[0] && back.length >= keys.length)
                    break;
            }
            root.check("8: Shift+Tab visits the cards bottom to top", back.length >= keys.length && back[0] === keys.length - 1);
        }, 50);

        // 9. Show All / Show Less: the focus follows the control, the layout converges.
        step(() => {
            // mail has m7 m6? m6 is cleared: m7 m3 m2 m1 -> four cards: collapsed shows three plus the toggle.
            for (let i = 0; i < 3; i++)
                root.add("mail");
        }, 400);
        step(() => {
            root.check("9: collapsed layout settled", root.layoutOk());
            const keys = Notifications.keysOf("mail");
            const lastShown = root.shownKeys().filter(x => keys.indexOf(x) >= 0).pop();
            const last = root.card(lastShown);
            root.check("9: last displayed card carries Show All", last.toggleCtl !== null && last.toggleCtl.visible);
            last.toggleCtl.forceActiveFocus();
            root.check("9: focus on Show All", win.activeFocusItem === last.toggleCtl);
            last.toggleCtl.clicked();
        }, 150);
        step(() => {
            const head = root.card(root.shownKeys()[0]);
            const mailHead = root.card(Notifications.centerModel.get(0).appName === "mail" ? Notifications.centerModel.get(0).key : "");
            const first = mailHead ? mailHead : head;
            root.check("9: Show All: the focus moved to Show Less", first && first.showLessCtl && first.showLessCtl.visible && win.activeFocusItem === first.showLessCtl);
        }, 500);
        step(() => {
            root.check("9: no stale offset after Show All", root.layoutOk());
            const first = root.card(Notifications.centerModel.get(0).key);
            first.showLessCtl.clicked();
        }, 150);
        step(() => {
            const keys = Notifications.keysOf("mail");
            const lastShown = root.shownKeys().filter(x => keys.indexOf(x) >= 0).pop();
            const last = root.card(lastShown);
            root.check("9: Show Less: the focus moved back to Show All", last && last.toggleCtl && win.activeFocusItem === last.toggleCtl);
        }, 500);
        step(() => {
            root.check("9: no stale offset after Show Less", root.layoutOk());
            // Toggled mid-animation, repeatedly: still converges.
            const first = () => root.card(Notifications.centerModel.get(0).key);
            Notifications.setExpanded("mail", true);
        }, 60);
        step(() => {
            Notifications.setExpanded("mail", false);
        }, 60);
        step(() => {
            Notifications.setExpanded("mail", true);
        }, 90);
        step(() => {
            Notifications.setExpanded("mail", false);
        }, 700);
        step(() => {
            root.check("9: converges after rapid toggles", root.layoutOk());
            Notifications.setExpanded("mail", true);
        }, 700);
        step(() => {
            root.check("9: converges expanded", root.layoutOk());
            Notifications.setExpanded("mail", false);
        }, 700);
        step(() => {
            root.check("9: converges collapsed again", root.layoutOk());
        }, 50);

        // 10. bumpTick: many bumps in a frame count once; nothing keeps ticking once the layout rests.
        step(() => {
            k.t0 = list.motionTick;
            for (let i = 0; i < 100; i++)
                list.bumpTick();
        }, 100);
        step(() => {
            root.check("10: 100 bumps in a frame are one tick", list.motionTick === k.t0 + 1);
            k.t1 = list.motionTick;
        }, 300);
        step(() => {
            root.check("10: no ticks at rest", list.motionTick === k.t1);
            // An arrival moves the cards below: ticks while they glide.
            root.add("other");
        }, 60);
        step(() => {
            root.check("10: ticks while the layout moves", list.motionTick > k.t1);
        }, 600);

        // 11. takeFresh: an arrival animates in once; a card that is only revealed does not.
        step(() => {
            k.fresh = root.add("fresh");
        }, 40);
        step(() => {
            const key = k.fresh;
            root.check("11: arrival was taken by its card", Notifications.freshKeys[key] === undefined);
            const c = root.card(key);
            root.check("11: arrival starts out", c !== null && (c.opacity < 1 || c.slide > 0));
            root.check("11: a taken key is not fresh again", Notifications.takeFresh(key) === false);
            Notifications.freshKeys["fake-key"] = true;
            root.check("11: takeFresh returns true once", Notifications.takeFresh("fake-key") === true && Notifications.takeFresh("fake-key") === false);
        }, 700);
        step(() => {
            const c = root.card(root.shownKeys()[0]);
            root.check("11: arrival settled", c.opacity === 1 && c.slide === 0 && root.layoutOk());
            Notifications.setExpanded("mail", true);
        }, 30);
        step(() => {
            const revealed = Notifications.keysOf("mail").slice(-1)[0];
            const c = root.card(revealed);
            root.check("11: a revealed card does not animate in", c !== null && c.opacity === 1 && c.slide === 0);
            Notifications.setExpanded("mail", false);
        }, 700);

        // 12. Group clear with the focus in the group: the next group's card; last card of all: the panel.
        step(() => {
            const mailKey = Notifications.keysOf("mail").filter(x => root.card(x) !== null)[0];
            root.check("12: focus a mail card", root.focusCard(mailKey));
            root.card(mailKey).clearCard(true, false);
        }, 300);
        step(() => {
            root.check("12: group clear: focus on a live card of another group", root.focusIsLive() && Notifications.keysOf("mail").length === 0);
            for (const a of ["other", "cal", "fresh"])
                Notifications.clearApp(a);
        }, 300);
        step(() => {
            root.check("12: everything cleared", Notifications.count === 0 && list.count === 0);
            root.check("12: no card holds the focus", list.focusedDelegate() === null && list.focusId === null);
            root.check("12: the panel has it", root.atPanel());
        }, 50);

        // ---- The focus invariant: a focused CONTROL that gets hidden, several changes in one turn, expiries ----
        const CLOSED = NotificationCloseReason.CloseRequested;
        const mailBy = n => {
            const out = [];
            for (let i = 0; i < n; i++)
                out.push(root.add("mail", {nid: 500 + root.seq}));
            return out;
        };

        // 13. Clear All focused on a group of two, a Mail notification arrives: Clear All moves to the new head card; the focus
        // goes to the old head card (visible ring), Return opens that card and leaves the arrival and the rest alone.
        root.scene(s => {
            s.m = mailBy(2);
        }, s => {
            root.check("13: focus Clear All of the head", root.focusCtl(s.m[1], "clearGroup"));
            s.m.push(root.add("mail"));
        }, s => {
            root.check("13: arrival is the new head", root.shownOf("mail")[0] === s.m[2]);
            root.check("13: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("13: on the old head card, ring visible", root.held() === s.m[1] && root.ident().role === "card" && root.card(s.m[1]).rowItem.activeFocus);
            keys.keyClick(Qt.Key_Return);
            root.check("13: Return did not clear the group nor the arrival", Notifications.entryFor(s.m[2]) !== null && Notifications.entryFor(s.m[0]) !== null);
            root.check("13: Return acted on the focused card only", Notifications.entryFor(s.m[1]) === null && Notifications.keysOf("mail").length === 2);
        });

        // 14. Show Less focused on an expanded group, an arrival moves Show Less to the new head card.
        root.scene(s => {
            s.m = mailBy(4);
            Notifications.setExpanded("mail", true);
        }, s => {
            root.check("14: focus Show Less", root.focusCtl(s.m[3], "showLess"));
            s.m.push(root.add("mail"));
        }, s => {
            root.check("14: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("14: on the old head card", root.held() === s.m[3] && root.ident().role === "card");
            root.check("14: nothing was collapsed or cleared by it", Notifications.keysOf("mail").length === 5 && Notifications.expandedApps.mail === true);
        });

        // 15. Show All (n) focused, the hidden 4th card closes: the group has three cards, Show All is gone.
        root.scene(s => {
            s.m = mailBy(4);
        }, s => {
            root.check("15: focus Show All", root.focusCtl(s.m[1], "showAll"));
            Notifications.closed(s.m[0], CLOSED);
        }, s => {
            root.check("15: Show All is gone", root.ctl(s.m[1], "showAll") === null);
            root.check("15: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("15: on the card that carried it", root.held() === s.m[1] && root.ident().role === "card");
        });

        // 16. Show Less focused, the expanded group shrinks to three cards: Show Less is gone.
        root.scene(s => {
            s.m = mailBy(4);
            Notifications.setExpanded("mail", true);
        }, s => {
            root.check("16: focus Show Less", root.focusCtl(s.m[3], "showLess"));
            Notifications.closed(s.m[0], CLOSED);
        }, s => {
            root.check("16: Show Less is gone", root.ctl(s.m[3], "showLess") === null);
            root.check("16: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("16: on the head card", root.held() === s.m[3] && root.ident().role === "card");
        });

        // 17. Clear All focused on a group of two, the app closes the other card: no group left to clear.
        root.scene(s => {
            s.m = mailBy(2);
        }, s => {
            root.check("17: focus Clear All", root.focusCtl(s.m[1], "clearGroup"));
            Notifications.closed(s.m[0], CLOSED);
        }, s => {
            root.check("17: Clear All is gone", root.ctl(s.m[1], "clearGroup") === null);
            root.check("17: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("17: on the remaining card", root.held() === s.m[1] && root.ident().role === "card");
            keys.keyClick(Qt.Key_Return);
            root.check("17: Return acts on the card only", Notifications.count === 0);
        });

        // 18. Show All focused, an arrival pushes its card out of the collapsed group: the Show All now in that slot keeps it.
        root.scene(s => {
            s.m = mailBy(4);
        }, s => {
            root.check("18: focus Show All", root.focusCtl(s.m[1], "showAll"));
            s.m.push(root.add("mail"));
        }, s => {
            root.check("18: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("18: on the Show All of the new third card", root.held() === s.m[2] && root.ident().role === "showAll");
        });

        // 19. B2: two arrivals in ONE turn with the focus on the third card.
        root.scene(s => {
            s.m = mailBy(3);
            s.c = root.add("cal");
        }, s => {
            root.check("19: focus the third card", root.focusCtl(s.m[0], "card"));
            s.m.push(root.add("mail"));
            s.m.push(root.add("mail"));
        }, s => {
            root.check("19: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("19: on the card now in that slot, not the panel", root.held() === s.m[2] && win.activeFocusItem !== panel && !root.atPanel());
        });

        // 20. B1: the app closes the focused card and its neighbour in ONE turn.
        root.scene(s => {
            s.m = mailBy(4);
            s.c = root.add("cal");
        }, s => {
            root.check("20: focus the second card", root.focusCtl(s.m[2], "card"));
            Notifications.closed(s.m[2], CLOSED);
            Notifications.closed(s.m[1], CLOSED);
        }, s => {
            root.check("20: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("20: on the card now in that slot (the revealed one)", root.held() === s.m[0] && win.activeFocusItem !== panel && !root.atPanel());
        });

        // 21. Three changes in one turn on the x of a card: a group clear of another app, an arrival, an expiry.
        root.scene(s => {
            s.m = mailBy(3);
            s.c = [root.add("cal"), root.add("cal")];
            s.o = root.add("other");
        }, s => {
            root.check("21: focus the x of a card", root.focusCtl(s.c[0], "close"));
            Notifications.clearKeys(Notifications.keysOf("mail"));
            s.o2 = root.add("other");
            Notifications.closed(s.o, CLOSED);
            Notifications.closed(s.c[0], CLOSED);
        }, s => {
            root.check("21: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("21: on the remaining card of its group", root.held() === s.c[1] && root.ident().role === "card");
        });

        // 22. The only card of a group (the middle one: chat, cal, mail) is closed by the app while the focus is on its x: the next
        // group's first card (visual order), not the first row, not the panel.
        root.scene(s => {
            s.m = mailBy(2);
            s.c = root.add("cal");
            s.h = root.add("chat");
        }, s => {
            root.check("22: order chat, cal, mail", root.shownKeys().join() === [s.h, s.c, s.m[1], s.m[0]].join());
            root.check("22: focus the x of the cal card", root.focusCtl(s.c, "close"));
            Notifications.closed(s.c, CLOSED);
        }, s => {
            root.check("22: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("22: on the next group's first card", root.held() === s.m[1] && root.ident().role === "card");
        });

        // 23. More hides itself while focused: the focus lands on the first button it revealed; Return then acts on it.
        root.scene(s => {
            s.k = root.add("act", {nid: 7, actions: [1, 2, 3, 4, 5].map(i => ({id: "a" + i, text: "Action " + i}))});
        }, s => {
            root.check("23: five buttons, More shown", root.ctl(s.k, "more") !== null && root.ctl(s.k, "action:a3") !== null && root.ctl(s.k, "action:a4") === null);
            root.check("23: focus More", root.focusCtl(s.k, "more"));
            keys.keyClick(Qt.Key_Return);
        }, s => {
            root.check("23: More is gone, the rest shown", root.ctl(s.k, "more") === null && root.ctl(s.k, "action:a5") !== null);
            root.check("23: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("23: on the first revealed button", root.ident().key === s.k && root.ident().role === "action:a4");
        });

        // 24. The sender's notification expires while an action button holds the focus: the buttons vanish, the focus goes to the card.
        root.scene(s => {
            s.k = root.add("act", {nid: 8, actions: [{id: "yes", text: "Yes"}, {id: "no", text: "No"}]});
        }, s => {
            root.check("24: focus an action", root.focusCtl(s.k, "action:no"));
            Notifications.closed(s.k, NotificationCloseReason.Expired);
        }, s => {
            root.check("24: the buttons are gone", root.ctl(s.k, "action:no") === null && Notifications.entryFor(s.k) !== null);
            root.check("24: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("24: on the card", root.held() === s.k && root.ident().role === "card");
        });

        // 25. The same-id update by the app (actions replaced) with the focus on an action: the card keeps it.
        root.scene(s => {
            s.k = root.add("act", {nid: 9, actions: [{id: "yes", text: "Yes"}, {id: "no", text: "No"}]});
        }, s => {
            root.check("25: focus an action", root.focusCtl(s.k, "action:no"));
            const e = Notifications.entryFor(s.k);
            Notifications.updateEntry(s.k, Object.assign({}, e, {actions: [{id: "yes", text: "Yes"}]}));
        }, s => {
            root.check("25: the replaced action is gone", root.ctl(s.k, "action:no") === null);
            root.check("25: focus is on a usable element, on that card", root.onUsable() && root.held() === s.k);
        });

        // 26. A key never acts on a hidden control, even before the resolver ran: hide the focused Clear All and press Return.
        root.scene(s => {
            s.m = mailBy(2);
        }, s => {
            const c = root.ctl(s.m[1], "clearGroup");
            root.check("26: focus Clear All", root.focusCtl(s.m[1], "clearGroup"));
            c.visible = false;
            keys.keyClick(Qt.Key_Return);
            keys.keyClick(Qt.Key_Space);
            s.cleared = Notifications.keysOf("mail").length !== 2;
        }, s => {
            root.check("26: neither Return nor Space acted on the hidden control", !s.cleared);
            root.check("26: the focus left it", root.noHiddenFocus());
        });

        // 28. Case 1a: the app replaces its notification (same id) and drops ANOTHER action while an action button holds the focus: the
        // buttons are rebuilt, the focus falls to their Loader; it goes back to the button (ring), and Return neither opens the card nor
        // closes the column.
        root.scene(s => {
            s.k = root.add("act", {nid: 11, actions: [{id: "a", text: "A"}, {id: "b", text: "B"}, {id: "c", text: "C"}]});
        }, s => {
            root.check("28: focus action b", root.focusCtl(s.k, "action:b"));
            const e = Notifications.entryFor(s.k);
            Notifications.updateEntry(s.k, Object.assign({}, e, {actions: [{id: "b", text: "B"}, {id: "c", text: "C"}]}));
            s.count = Notifications.count;
        }, s => {
            root.check("28: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("28: on the button b, ring visible", root.ident() !== null && root.ident().key === s.k && root.ident().role === "action:b" && win.activeFocusItem.activeFocus);
            keys.keyClick(Qt.Key_Return);
            root.check("28: Return did not open the card nor close the column", Notifications.count === s.count && Notifications.centerOpen);
            keys.keyClick(Qt.Key_Delete);
            root.check("28: Delete on a button does nothing", Notifications.count === s.count);
        });

        // 29. Case 1b: an arrival pushes the focused card out of the collapsed group and an app close brings it back in, in ONE turn:
        // the focus does not fall to the list; Delete clears that card.
        root.scene(s => {
            s.m = mailBy(3);
            s.c = root.add("cal");
        }, s => {
            root.check("29: focus the third card", root.focusCtl(s.m[0], "card"));
            s.m.push(root.add("mail"));
            Notifications.closed(s.m[1], CLOSED);
        }, s => {
            root.check("29: the card is displayed again", root.shownKeys().indexOf(s.m[0]) >= 0);
            root.check("29: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
            root.check("29: not on the list or the panel", win.activeFocusItem !== list && !root.atPanel());
            keys.keyClick(Qt.Key_Delete);
            root.check("29: Delete acts on a card", Notifications.count === 3 && Notifications.entryFor(s.m[0]) === null);
        });

        // 30. Delete and Backspace act only on the card and its x: on Clear All, Show All and an action they do nothing.
        root.scene(s => {
            s.m = mailBy(4);
            s.k = root.add("act", {nid: 12, actions: [{id: "a", text: "A"}]});
        }, s => {
            s.n = Notifications.count;
            root.check("30: focus Show All", root.focusCtl(s.m[1], "showAll"));
            keys.keyClick(Qt.Key_Delete);
            keys.keyClick(Qt.Key_Backspace);
            root.check("30: focus Clear All", root.focusCtl(s.m[3], "clearGroup"));
            keys.keyClick(Qt.Key_Delete);
            root.check("30: focus an action", root.focusCtl(s.k, "action:a"));
            keys.keyClick(Qt.Key_Backspace);
            s.same = Notifications.count === s.n;
        }, s => {
            root.check("30: nothing was cleared by Delete or Backspace on those controls", s.same && Notifications.count === 5);
            root.check("30: Delete on the x clears its card", root.focusCtl(s.k, "close"));
            keys.keyClick(Qt.Key_Delete);
            root.check("30: that card is gone", Notifications.entryFor(s.k) === null && Notifications.count === 4);
        });

        // 31. The identity's rank follows the layout when the focused card itself stays: focus the 2nd card of a group of three, one
        // arrival of the same app (the card is now the 3rd), settled; Delete clears it and the focus goes to the card that slid into
        // ITS slot (the 3rd, revealed), not to the card above.
        root.scene(s => {
            s.m = mailBy(3);
            s.c = root.add("cal");
        }, s => {
            root.check("31: focus the second card", root.focusCtl(s.m[1], "card"));
            s.m.push(root.add("mail"));
        }, s => {
            root.check("31: the card is the third now", root.shownOf("mail").indexOf(s.m[1]) === 2 && root.held() === s.m[1]);
            root.check("31: its identity says rank 2", list.focusId !== null && list.focusId.rank === 2);
            keys.keyClick(Qt.Key_Delete);
            root.check("31: the card that slid into the slot has the focus", root.held() === s.m[0] && root.onUsable());
        });

        // 32. The settled rows follow the layout too: groups a, b, c (a newest); the focus on b's card; an arrival of c moves c to the top;
        // b's card is closed by the app. The group is gone: the focus goes to the card before it (a), not to c, which the stale
        // order [a, b, c] would name next.
        root.scene(s => {
            s.c = root.add("gc");
            s.b = root.add("gb");
            s.a = root.add("ga");
        }, s => {
            root.check("32: order a, b, c", root.shownKeys().join() === [s.a, s.b, s.c].join());
            root.check("32: focus b", root.focusCtl(s.b, "card"));
            s.c2 = root.add("gc");
        }, s => {
            root.check("32: c moved to the top", root.shownKeys().join() === [s.c2, s.c, s.a, s.b].join());
            Notifications.closed(s.b, CLOSED);
        }, s => {
            root.check("32: b is gone", Notifications.entryFor(s.b) === null);
            root.check("32: focus on the card before the gone group (a)", root.held() === s.a && root.onUsable());
        });

        // 33. A hidden Clear All holding the focus swallows only its activation keys: Escape reaches the panel.
        root.scene(s => {
            s.m = mailBy(2);
        }, s => {
            s.e0 = root.escapes;
            root.check("33: focus Clear All", root.focusCtl(s.m[1], "clearGroup"));
            root.ctl(s.m[1], "clearGroup").visible = false;
            keys.keyClick(Qt.Key_Escape);
            s.e1 = root.escapes;
        }, s => {
            root.check("33: Escape propagated to the panel", s.e1 === s.e0 + 1);
        });

        // 34. Keys in the SAME turn as the change that took the card out of the rows (before the resolver ran) do nothing: Delete on
        // a card an arrival has just pushed out of the collapsed group.
        root.scene(s => {
            s.m = mailBy(3);
        }, s => {
            root.check("34: focus the third card", root.focusCtl(s.m[0], "card"));
            s.m.push(root.add("mail"));
            keys.keyClick(Qt.Key_Delete);
            s.alive = Notifications.entryFor(s.m[0]) !== null;
        }, s => {
            root.check("34: Delete did not clear the card that left the rows", s.alive && Notifications.count === 4);
            root.check("34: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
        });

        // 35. Space on a sender action of a card that left the rows in the same turn does not invoke it.
        root.scene(s => {
            root.fired = [];
            s.k = root.add("mail", {nid: 21, actions: [{id: "a", text: "A"}]});
            Notifications.liveByKey[s.k] = {actions: [{identifier: "a", invoke: () => root.fired.push("a")}], dismiss: () => {}};
            s.m = mailBy(2);
        }, s => {
            root.check("35: focus the action (third card)", root.focusCtl(s.k, "action:a"));
            s.m.push(root.add("mail"));
            keys.keyClick(Qt.Key_Space);
            s.n = root.fired.length;
        }, s => {
            root.check("35: the action was not invoked", s.n === 0 && root.fired.length === 0);
            root.check("35: focus is on a usable element", root.onUsable() && root.noHiddenFocus());
        });

        // 36. Return on the stray actions Loader (the focus a same-id update leaves there) does not open the card.
        root.scene(s => {
            s.k = root.add("act", {nid: 22, actions: [{id: "a", text: "A"}, {id: "b", text: "B"}]});
        }, s => {
            root.check("36: focus action b", root.focusCtl(s.k, "action:b"));
            const e = Notifications.entryFor(s.k);
            Notifications.updateEntry(s.k, Object.assign({}, e, {actions: [{id: "b", text: "B"}]}));
            s.stray = root.ident() !== null && root.ident().role === "";
            keys.keyClick(Qt.Key_Return);
            s.open = Notifications.centerOpen;
            s.count = Notifications.count;
        }, s => {
            root.check("36: Return did not open the card nor close the column", s.open && s.count === 1 && Notifications.count === 1);
            root.check("36: focus is back on the button", root.onUsable() && root.ident().role === "action:b");
        });

        // 27. Property: seeded random turns (arrivals, closes, expiries, toggles, clears; 1 to 3 per turn) with the focus anywhere.
        // After every turn the focus is on a usable element (the panel when no card is left), or where it was put outside the cards.
        step(() => root.resetAll(), 450);
        let state = 20261020;
        const rnd = n => {
            state = (state * 1103515245 + 12345) % 2147483648;
            return Math.floor(state / 65536) % n;
        };
        const apps = ["mail", "cal", "chat"];
        const live = ["a", "b", "c", "d", "e"];
        const P = {bad: 0, log: [], desc: "", outside: null, moved: 0, inList: 0, held: null};
        for (let t = 0; t < 80; t++) {
            step(() => {
                // The focus first: any card control, the panel, Edit Widgets.
                const all = root.targets();
                const pick = rnd(all.length + 3);
                P.outside = null;
                if (pick < all.length) {
                    all[pick].forceActiveFocus();
                    P.held = all[pick];
                } else if (pick === all.length) {
                    list.releaseFocus();
                    P.outside = panel;
                } else {
                    editStub.forceActiveFocus();
                    P.outside = editStub;
                }
                const had = Notifications.centerModel.count;
                const n = 1 + rnd(3);
                const desc = [];
                for (let i = 0; i < n; i++) {
                    const op = rnd(8);
                    const app = apps[rnd(apps.length)];
                    const mine = Notifications.history.map(e => e.key);
                    if (op <= 2 || mine.length === 0) {
                        const na = rnd(5);
                        root.add(app, na > 0 && rnd(2) === 0 ? {nid: 100 + root.seq, actions: live.slice(0, na).map(a => ({id: a, text: "Do " + a}))} : {});
                        desc.push("arrive:" + app);
                    } else if (op === 3) {
                        Notifications.closed(mine[rnd(mine.length)], CLOSED);
                        desc.push("close");
                    } else if (op === 4) {
                        Notifications.closed(mine[rnd(mine.length)], NotificationCloseReason.Expired);
                        desc.push("expire");
                    } else if (op === 5) {
                        Notifications.setExpanded(app, Notifications.expandedApps[app] !== true);
                        desc.push("toggle:" + app);
                    } else if (op === 6) {
                        Notifications.clearKeys(Notifications.keysOf(app));
                        desc.push("clearGroup:" + app);
                    } else {
                        Notifications.clear(mine[rnd(mine.length)]);
                        desc.push("clear");
                    }
                }
                P.desc = "turn " + t + " pick " + pick + "/" + all.length + " cards " + had + ": " + desc.join(",");
            }, 100);
            step(() => {
                let ok;
                if (P.outside !== null)
                    ok = P.outside === panel ? root.atPanel() : win.activeFocusItem === P.outside;
                else if (Notifications.centerModel.count === 0)
                    ok = root.atPanel();
                else
                    ok = root.onUsable();
                ok = ok && root.noHiddenFocus();
                if (P.outside === null) {
                    P.inList++;
                    if (win.activeFocusItem !== P.held)
                        P.moved++;
                }
                if (!ok) {
                    P.bad++;
                    if (P.log.length < 4)
                        P.log.push(P.desc + " f=" + win.activeFocusItem + " id=" + JSON.stringify(root.ident()));
                }
            }, 5);
        }
        step(() => {
            console.log("notif-center-list: property turns with the focus in the cards: " + P.inList + ", focus moved by the resolver: " + P.moved);
            root.check("27: the invariant held after every random turn (" + P.bad + " bad): " + P.log.join(" | "), P.bad === 0);
            root.check("27: the random turns really moved the focus", P.moved >= 10);
            root.resetAll();
        }, 450);
    }

    Timer {
        id: runner

        running: false
        repeat: false
        onTriggered: {
            if (root.stepAt >= root.steps.length) {
                if (root.failures.length === 0) {
                    console.log("notif-center-list: PASS");
                    Qt.exit(0);
                } else {
                    console.log("notif-center-list: FAIL " + root.failures.join(", "));
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
            console.log("notif-center-list: FAIL timeout at step " + root.stepAt + " " + root.failures.join(", "));
            Qt.exit(1);
        }
    }
}
