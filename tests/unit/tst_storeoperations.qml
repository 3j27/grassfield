import QtQuick
import QtTest
import Grassfield.Ui
import "store"

// Grassfield Store's Get, Open and Uninstall… (apps/store/qml; ADR-0037 step 3; spec SR13-SR22, SR30) with a fake backend:
// the confirmation sheet (checking, the plan, the refusals and Open Software Update), the button's states (Get, Open, the
// ring of a running or waiting operation, a waiting one leaving the queue), Uninstall… in the product page's menu and in an
// installed app's context menu with the reasons it is not offered, the queue in the toolbar, how an operation ended (Try
// Again, Details…), pacman's lock left behind, an app that could not be opened, and Ctrl+Q. Nothing installs or opens.
TestCase {
    id: testCase
    name: "StoreOperations"
    width: 800
    height: 600
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        FakeStoreBackend {}
    }

    function make(props) {
        const backend = fakeBackend.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, Object.assign({backend: backend, globalMenu: false}, props || {}));
        verify(win);
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is active");
        wait(50);
        tryVerify(() => win.page !== null);
        return {backend: backend, win: win};
    }

    // Items and the objects they hold (`data`: a Popup is not a child item), each visited once.
    function findAll(item, pred, out, seen) {
        out = out || [];
        seen = seen || [];
        if (!item || seen.indexOf(item) >= 0)
            return out;
        seen.push(item);
        // Items only (findPopup finds the menus): an attached Accessible on anything else warns.
        if (item.childrenRect !== undefined && pred(item))
            out.push(item);
        for (const k of item.data || item.children || [])
            findAll(k, pred, out, seen);
        if (item.contentItem && item.contentItem !== item)
            findAll(item.contentItem, pred, out, seen);
        return out;
    }

    function find(item, pred) {
        return findAll(item, pred)[0] || null;
    }

    // A MenuPopup (a Popup: not an item) held under `item`.
    function findPopup(item, pred, seen) {
        seen = seen || [];
        if (!item || seen.indexOf(item) >= 0)
            return null;
        seen.push(item);
        if (item.openAt !== undefined && item.closePolicy !== undefined && pred(item))
            return item;
        for (const k of item.data || item.children || []) {
            const hit = findPopup(k, pred, seen);
            if (hit)
                return hit;
        }
        return item.contentItem && item.contentItem !== item ? findPopup(item.contentItem, pred, seen) : null;
    }

    function sheet(t) {
        return find(t.win.contentItem, i => i.confirmEnabled !== undefined && i.plan !== undefined);
    }

    function textSheet(t) {
        return find(t.win.contentItem, i => i.confirmEnabled !== undefined && i.plan === undefined && i.text !== undefined && i.showCancel === false && i.title !== undefined);
    }

    function button(t, name) {
        return find(t.win.page, i => i.Accessible.role === Accessible.Button && i.Accessible.name === name);
    }

    function confirmButton(s) {
        return find(s, i => i.text === s.confirmText && i.primary !== undefined && i.destructive !== undefined && i !== s);
    }

    // Get: the sheet checks first (its button waits), then lists the plan; Install queues the operation and closes it.
    function test_getShowsThePlanThenInstalls() {
        const t = make({startPage: "app:org.example.Paint"});
        tryVerify(() => button(t, "Get Paint") !== null);
        mouseClick(button(t, "Get Paint"));
        const s = sheet(t);
        verify(s.visible);
        compare(s.title, "Install “Paint”?");
        compare(s.message, "Checking what this changes…");
        verify(!s.confirmEnabled, "Install waits for the plan");
        verify(t.backend.calls.indexOf("plan:install:org.example.Paint") >= 0);
        keyClick(Qt.Key_Return);
        verify(s.visible, "Return does nothing while it checks");
        t.backend.planReady("org.example.Paint", "install", {refusal: "", packages: [{name: "paint", version: "1-1", repo: "extra", size: "1.2 MB"},
            {name: "libbrush", version: "2-1", repo: "extra", size: "300 kB"}], download: "1.5 MB", installed: "6 MB", detail: ""});
        verify(s.confirmEnabled);
        compare(s.message, "These packages are installed:");
        compare(s.confirmText, "Install");
        verify(!s.destructive);
        const list = find(s, i => i.Accessible.role === Accessible.List);
        tryCompare(list, "count", 2);
        compare(list.itemAtIndex(0).Accessible.name, "paint, 1-1, 1.2 MB");
        verify(find(s, i => i.text === "GPL-3.0-or-later") !== null, "the licence");
        verify(find(s, i => i.text === "6 MB") !== null, "the installed size");
        keyClick(Qt.Key_Return);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:org.example.Paint") >= 0);
    }

    // Cancel (Esc) closes it and nothing runs (SR14).
    function test_cancelRunsNothing() {
        const t = make({startPage: "app:org.example.Paint"});
        tryVerify(() => button(t, "Get Paint") !== null);
        t.win.requestGet(t.backend.find("org.example.Paint"));
        const s = sheet(t);
        t.backend.planReady("org.example.Paint", "install", {refusal: "", packages: [{name: "paint", version: "1-1", repo: "extra", size: ""}]});
        keyClick(Qt.Key_Escape);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);
    }

    // A plan that cannot run says why (SR15): the last update unfinished or an outdated system offer Software Update; the
    // locks and the others only OK.
    function test_refusals() {
        const t = make({startPage: "app:org.example.Paint"});
        const s = sheet(t);
        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "unfinished", unfinished: ["linux 6.17-1 -> 6.18-1"], packages: []});
        compare(s.title, "Finish the system update first");
        compare(s.confirmText, "Open Software Update");
        verify(s.showCancel);
        verify(find(s, i => i.text === "linux 6.17-1 -> 6.18-1") !== null, "pacman's line");
        s.confirm();
        verify(t.backend.calls.indexOf("openSoftwareUpdate") >= 0);
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);

        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "outdated", packages: [], upgrades: ["glib2"], detail: ""});
        compare(s.title, "Update your system first");
        s.cancel();

        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "busy", packages: []});
        compare(s.title, "Another installation or an update is running");
        compare(s.confirmText, "OK");
        verify(!s.showCancel);
        s.confirm();
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);

        t.win.requestUninstall(t.backend.find("org.example.Photo"));
        t.backend.planReady("org.example.Photo", "remove", {refusal: "dependency", dependents: ["accountsservice", "gtk3"], packages: []});
        compare(s.title, "“Photo Lab” can't be uninstalled");
        compare(s.message, "Other apps need it: accountsservice, gtk3.");
        s.confirm();
        t.win.requestUninstall(t.backend.find("org.example.Photo"));
        t.backend.planReady("org.example.Photo", "remove", {refusal: "protected", protected: "efibootmgr", packages: []});
        compare(s.title, "Uninstalling it would also remove part of the system");
        verify(s.message.indexOf("efibootmgr") >= 0);
        s.confirm();
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") < 0);
    }

    // A web app: the sheet alone (owner ST3), no package list.
    function test_webAppSheet() {
        const t = make({startPage: "app:org.example.Mail"});
        const s = sheet(t);
        t.win.requestGet(t.backend.find("org.example.Mail"));
        t.backend.planReady("org.example.Mail", "install", {refusal: "", packages: []});
        compare(s.message, "A launcher that opens mail.example.com in your browser is added to Apps, with its icon.");
        compare(findAll(s, i => i.Accessible.role === Accessible.ListItem).length, 0);
        s.confirm();
        verify(t.backend.calls.indexOf("install:org.example.Mail") >= 0);
    }

    // The button (SR13, SR18): Open opens; while its operation runs, a ring with its count; a waiting one shows a square
    // that takes it out of the queue; the queue's button in the toolbar.
    function test_buttonStatesAndQueue() {
        const t = make({startPage: "app:org.example.Photo"});
        tryVerify(() => button(t, "Open Photo Lab") !== null);
        mouseClick(button(t, "Open Photo Lab"));
        compare(t.backend.opened, ["org.example.Photo"]);
        t.backend.openWorks = false;
        mouseClick(button(t, "Open Photo Lab"));
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        compare(notice.text, "“Photo Lab” could not be opened.");

        const queue = find(t.win.contentItem, i => i.accessibleName !== undefined && i.iconName === "arrow-down-circle");
        verify(queue);
        verify(!queue.visible);
        t.win.openPage("app:org.example.Paint");
        tryVerify(() => button(t, "Get Paint") !== null);
        t.backend.operations = [{id: "op0", app: "org.example.Photo", name: "Photo Lab", kind: "remove", state: "running", blocked: false, done: 0, total: 1},
                                {id: "op1", app: "org.example.Paint", name: "Paint", kind: "install", state: "waiting", blocked: false, done: 0, total: 3}];
        verify(queue.visible);
        verify(button(t, "Get Paint") === null || !button(t, "Get Paint").visible, "the ring in the button's place");
        const ring = find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible);
        verify(ring);
        verify(ring.stop);
        compare(ring.Accessible.name, "Remove Paint from the queue");
        compare(ring.Accessible.description, "Waiting");
        mouseClick(ring);
        verify(t.backend.calls.indexOf("removeWaiting:op1") >= 0);

        t.backend.operations = [{id: "op2", app: "org.example.Paint", name: "Paint", kind: "install", state: "running", blocked: false, done: 2, total: 4}];
        const running = find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible);
        verify(!running.stop);
        verify(!running.indeterminate);
        compare(running.value, 0.5);
        compare(running.Accessible.description, "Installing: 2 of 4");
        t.backend.operations = [{id: "op2", app: "org.example.Paint", name: "Paint", kind: "install", state: "authorizing", blocked: false, done: 0, total: 4}];
        compare(find(t.win.page, i => i.stop !== undefined && i.visible).Accessible.description, "Waiting for permission…");
    }

    // Uninstall… (SR22): in the product page's menu when the Store may remove the app, with the reason otherwise.
    function test_uninstallFromTheProductPage() {
        const t = make({startPage: "app:org.example.Photo"});
        const more = find(t.win.page, i => i.Accessible.role === Accessible.ButtonMenu && i.visible);
        verify(more, "the … button of an installed app");
        compare(more.Accessible.name, "More for Photo Lab");
        more.openMenu();
        const menu = findPopup(t.win.page, i => i.app === undefined);
        tryVerify(() => menu.opened);
        compare(menu.items[0].text, "Uninstall…");
        verify(menu.items[0].enabled);
        menu.chosen("uninstall");
        const s = sheet(t);
        verify(s.visible);
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        compare(s.title, "Uninstall “Photo Lab”?");
        compare(s.confirmText, "Uninstall");
        verify(s.destructive);
        s.confirm();
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") >= 0);
        menu.close();

        t.backend.blocks = {"org.example.Photo": {uninstall: "omarchy"}};
        t.backend.revision++;
        verify(find(t.win.page, i => i.text === "Part of Omarchy" && i.visible) !== null);
        more.openMenu();
        verify(!menu.items[0].enabled);
        menu.close();
    }

    // The context menu of an installed app's item in Installed (SR22, SR23): Open, Show in Store, Uninstall….
    function test_contextMenu() {
        const t = make();
        t.win.openInstalled();
        tryVerify(() => t.win.pageKind === "installed");
        const lockup = find(t.win.page, i => i.app !== undefined && i.opened !== undefined && i.app.id === "org.example.Photo");
        verify(lockup);
        mouseClick(lockup, 10, 10, Qt.RightButton);
        const menu = findPopup(t.win.contentItem, i => i.app !== undefined);
        tryVerify(() => menu.opened);
        compare(menu.items.filter(i => !i.separator).map(i => i.text), ["Open", "Show in Store", "Uninstall…"]);
        menu.chosen("open");
        compare(t.backend.opened, ["org.example.Photo"]);
        menu.close();
        // A web app our catalog does not list: Open and Uninstall…, no page.
        const notes = find(t.win.page, i => i.app !== undefined && i.opened !== undefined && i.app.id === "webapp:Notes");
        mouseClick(notes, 10, 10, Qt.RightButton);
        tryVerify(() => menu.opened);
        compare(menu.items.filter(i => !i.separator).map(i => i.text), ["Open", "Uninstall…"]);
        menu.chosen("uninstall");
        verify(t.backend.calls.indexOf("plan:remove:webapp:Notes") >= 0);
        menu.close();
    }

    // How an operation ended (SR19, SR20): a line with Try Again and Details…; pacman's lock left behind, with Arch's way.
    function test_resultsAndLock() {
        const t = make();
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        verify(!notice.visible);
        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "interrupted", present: 15, total: 110,
                             details: "error: failed to commit transaction (conflicting files)"}};
        compare(notice.text, "“Paint”: The installation was interrupted: 15 of 110 packages were installed.");
        compare(notice.actions.map(a => a.text), ["Try Again", "Details…", "Close"]);
        notice.acted("details");
        const details = textSheet(t);
        verify(details && details.visible);
        compare(details.text, "error: failed to commit transaction (conflicting files)");
        details.confirm();
        notice.acted("again");
        verify(t.backend.calls.indexOf("dismiss:org.example.Paint") >= 0);
        verify(t.backend.calls.indexOf("plan:install:org.example.Paint") >= 0);
        verify(sheet(t).visible);
        sheet(t).cancel();

        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "cancelled", present: 0, total: 1, details: ""}};
        verify(!notice.visible, "a cancelled request says nothing");
        t.backend.results = {};
        t.backend.staleLock = true;
        compare(notice.text, "A package manager stopped mid-way and left its lock: nothing installs until it goes.");
        notice.acted("lock");
        compare(details.text, "sudo rm /var/lib/pacman/db.lck");
        verify(details.message.indexOf("no pacman is running") >= 0);
        details.confirm();
    }

    // The product page says how its last operation ended, with Try Again and Details….
    function test_resultOnTheProductPage() {
        const t = make({startPage: "app:org.example.Paint"});
        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "failed", present: 0, total: 1, details: "error"}};
        tryVerify(() => find(t.win.page, i => i.text === "The installation failed." && i.visible) !== null);
        const again = find(t.win.page, i => i.text === "Try Again" && i.activated !== undefined);
        again.activated();
        verify(sheet(t).visible);
        sheet(t).cancel();
    }

    // Ctrl+Q: the backend quits once the running operation ended (ADR-0037 f).
    function test_quitWaitsForTheOperation() {
        const t = make();
        keyClick(Qt.Key_Q, Qt.ControlModifier);
        verify(t.backend.calls.indexOf("quitWhenIdle") >= 0);
    }
}
