pragma ComponentBehavior: Bound
import QtQuick
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
//  - bumpTick coalesces a frame's bumps; takeFresh animates an arrival once and never a card that is merely revealed.
// Prints "notif-center-list: PASS" or the failures.
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
            panel.forceActiveFocus();
            root.check("focusedDelegate: none on the panel", list.focusedDelegate() === null);
            root.check("focus card", root.focusCard(k.m4));
            list.tabStep(true);
            root.check("focusedDelegate: card or its x", root.held() === k.m4 && root.card(k.m4).rowItem.activeFocus === false);
            root.check("tracked key follows the focus", Notifications.centerFocusKey === k.m4);
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
            root.check("1: tracked key", Notifications.centerFocusKey === k.m4);
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
            panel.forceActiveFocus();
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
            root.check("12: no card holds the focus", list.focusedDelegate() === null && Notifications.centerFocusKey === "");
            root.check("12: the panel has it", panel.activeFocus);
        }, 50);
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
