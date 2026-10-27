import QtQuick
import QtTest
import Grassfield.Ui

// Settings' window (apps/settings/qml/Main.qml): Battery in the sidebar only with a laptop battery (UPower's display device),
// Mouse and Trackpad shown for the pointers there are (MouseTrackpad.paneFor), the pages' requests opening their sheets and the
// sheets' answers reaching the page, and every sheet giving the keyboard focus back to what opened it. The backend is a fake in
// a dev session: nothing reaches a bus, a tool or a file.
TestCase {
    id: testCase
    name: "SettingsMain"
    width: 800
    height: 700
    visible: true
    when: windowShown

    // /proc/bus/input/devices: an I2C touchpad (and its own mouse node), a USB mouse (tst_mousetrackpad.qml's fixtures).
    readonly property string touchpad: "I: Bus=0018 Vendor=0F1E Product=0101 Version=0100\nN: Name=\"GF Touchpad\"\nH: Handlers=mouse1 event8 \n"
        + "B: PROP=5\nB: EV=1b\nB: KEY=e520 10000 0 0 0 0\nB: ABS=2e0800000000003\n\n"
        + "I: Bus=0018 Vendor=0F1E Product=0101 Version=0100\nN: Name=\"GF Mouse\"\nH: Handlers=mouse0 event7 \nB: PROP=0\nB: EV=17\n"
        + "B: KEY=30000 0 0 0 0\nB: REL=3\n"
    readonly property string mouse: "I: Bus=0003 Vendor=3c52 Product=0001 Version=0100\nN: Name=\"USB Mouse\"\nH: Handlers=mouse2 event9 \n"
        + "B: PROP=0\nB: EV=17\nB: KEY=1f0000 0 0 0 0\nB: REL=1943\n"
    readonly property string battery: JSON.stringify({present: true, onBattery: true, percent: 71.6, state: 2, timeToEmpty: 3900, timeToFull: 0,
        capacity: 91.5, cycles: 212, limitSupported: true, limitEnabled: false, limitEnd: 80, history24: [], history10: []})

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: true
            readonly property string configFile: "/home/u/.config/grassfield/grassfield.json"
            readonly property string capabilitiesFile: "/run/user/1000/grassfield/capabilities.json"
            readonly property string bindingsFile: "/home/u/.config/hypr/bindings.lua"
            readonly property string stateDir: "/home/u/.local/state"
            readonly property string homeDir: "/home/u"
            readonly property var applicationDirs: ["/home/u/.local/share/applications", "/usr/share/applications"]
            property var files: ({})
            property var busQueries: []
            property var queries: []
            property var actions: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function writeText(path: string, text: string): string {
                return "";
            }
            function watch(path: string): void {
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push(argv);
                return true;
            }
            function busAct(what: string, op: var, tag: string): bool {
                actions.push(op);
                return true;
            }
            // Storage > All Volumes… (Backend::volumes).
            function volumes(): var {
                return [];
            }
        }
    }

    function make(devices, props) {
        // The backend outlives the window (the pages read it until they go): it goes with the test case.
        const backend = fakeBackend.createObject(testCase);
        backend.files = {"/proc/bus/input/devices": devices};
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, Object.assign({backend: backend, globalMenu: false}, props || {}));
        verify(win);
        return {backend: backend, win: win};
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
        return null;
    }

    function ids(win) {
        return win.available.map(s => s.id);
    }

    // The sheet that has this signal or function (each sheet has its own), and that `also` accepts.
    function sheet(win, member, also) {
        const s = win.sheets.find(x => x[member] !== undefined && (also === undefined || also(x)));
        verify(s, member);
        return s;
    }

    function shownSheet(win) {
        return win.sheets.find(x => x.shown) ?? null;
    }

    // UPower's display device decides: a laptop battery shows Battery, none (or no answer) hides it.
    function test_hasBattery() {
        const t = make(testCase.touchpad);
        compare(t.backend.busQueries.filter(q => q.tag === "main.power").map(q => q.what), ["power.state"]);
        verify(!t.win.hasBattery);
        verify(ids(t.win).indexOf("battery") < 0);
        t.backend.finished("main.power", true, testCase.battery);
        verify(t.win.hasBattery);
        verify(ids(t.win).indexOf("battery") >= 0);
        t.backend.finished("main.power", true, JSON.stringify({present: false}));
        verify(!t.win.hasBattery);
        t.backend.finished("main.power", true, testCase.battery);
        t.backend.finished("main.power", false, "");
        verify(!t.win.hasBattery, "UPower not answering: no Battery");
        verify(ids(t.win).indexOf("battery") < 0);
    }

    // Mouse while a mouse is there, Trackpad where there is one; asked for the other, the one there is shown.
    function test_pointerPane() {
        const pad = make(testCase.touchpad);
        verify(!pad.win.hasMouse && pad.win.hasTouchpad);
        compare(pad.win.pointerPane("mouse"), "trackpad");
        compare(pad.win.pointerPane("sound"), "sound");
        verify(ids(pad.win).indexOf("mouse") < 0 && ids(pad.win).indexOf("trackpad") >= 0);
        pad.win.select("mouse");
        compare(pad.win.selectedId, "trackpad");
        const started = make(testCase.touchpad, {startSection: "mouse"});
        compare(started.win.selectedId, "trackpad", "--section=mouse on a laptop without a mouse");
        const desk = make(testCase.mouse);
        verify(desk.win.hasMouse && !desk.win.hasTouchpad);
        compare(desk.win.pointerPane("trackpad"), "mouse");
        desk.win.select("trackpad");
        compare(desk.win.selectedId, "mouse");
        // A mouse plugged in later: read again with the system state, the pane stays the one asked for.
        desk.backend.files = {"/proc/bus/input/devices": testCase.touchpad + "\n" + testCase.mouse};
        desk.win.readPointers();
        verify(desk.win.hasMouse && desk.win.hasTouchpad);
        desk.win.select("trackpad");
        compare(desk.win.selectedId, "trackpad");
        // The touchpad gone while its pane shows: the mouse's.
        desk.backend.files = {"/proc/bus/input/devices": testCase.mouse};
        desk.win.readPointers();
        compare(desk.win.selectedId, "mouse");
    }

    // A page's request opens its sheet; the sheet's answer reaches the page.
    function test_sheetWiring() {
        const t = make(testCase.touchpad);
        t.backend.finished("main.power", true, testCase.battery);
        // Battery > (i) Charging: the sheet; its charge limit goes to the page (refused in a dev session: the page's note).
        t.win.select("battery");
        const batteryPage = find(t.win.contentItem, i => i.infoRequested !== undefined && i.setLimit !== undefined);
        verify(batteryPage);
        batteryPage.infoRequested("charging", batteryPage.power);
        const info = sheet(t.win, "limitRequested");
        verify(info.shown);
        compare(info.topic, "charging");
        info.limitRequested(true);
        verify(!info.shown, "the answer closes the sheet");
        // Printers: a printer's sheet, then Remove Printer…'s confirmation.
        t.win.select("printers");
        const printers = find(t.win.contentItem, i => i.detailsRequested !== undefined && i.addRequested !== undefined);
        verify(printers);
        printers.detailsRequested({name: "GF_Office", title: "GF Office", status: "Idle", message: "", location: "", kind: "USB", isDefault: false,
            needsResume: false});
        const details = sheet(t.win, "resumeRequested");
        verify(details.shown);
        compare(details.printer.name, "GF_Office");
        details.removeRequested(details.printer);
        const remove = sheet(t.win, "remove");
        verify(remove.shown);
        // The options of Menu Bar, Lock Screen, Desktop & Dock and Search, each a sheet over the window.
        const cases = [{id: "menubar", signal: "clockOptionsRequested"}, {id: "menubar", signal: "batteryOptionsRequested"},
            {id: "lock", signal: "messageRequested"}, {id: "desktop", signal: "screenCornersRequested"}, {id: "search", signal: "historyDeleteRequested"}];
        for (const c of cases) {
            for (const s of t.win.sheets)
                s.close();
            t.win.select(c.id);
            const p = find(t.win.contentItem, i => i[c.signal] !== undefined);
            verify(p, c.signal);
            p[c.signal]();
            verify(shownSheet(t.win) !== null, c.signal);
        }
        // Screen Saver > Lock Screen Settings…: the sheet closes and Lock Screen shows.
        for (const s of t.win.sheets)
            s.close();
        const saver = sheet(t.win, "lockScreenRequested");
        saver.open();
        saver.lockScreenRequested();
        verify(!saver.shown);
        compare(t.win.selectedId, "lock");
    }

    // Every sheet of the window is in `sheets`, and each one gives the keyboard focus back to what had it when it appeared.
    function test_sheetsGiveTheFocusBack() {
        const t = make(testCase.touchpad);
        let count = 0;
        find(t.win.contentItem, i => {
            if (i.focusBack !== undefined && i.confirmText !== undefined)
                count++;
            return false;
        });
        compare(t.win.sheets.length, count, "every sheet is listed");
        verify(count >= 23);
        for (const s of t.win.sheets) {
            t.win.searchField.forceActiveFocus();
            verify(t.win.searchField.activeFocus);
            s.open();
            verify(s.shown);
            verify(!t.win.searchField.activeFocus, s.title);
            s.close();
            verify(t.win.searchField.activeFocus, "back from " + s.title);
        }
        // A sheet opened from another one gives the focus back to that one's control.
        const sources = sheet(t.win, "addRequested");
        sources.open();
        const inSheet = t.win.activeFocusItem;
        verify(inSheet !== t.win.searchField);
        // Its +: the layout picker (not Add Printer…, which has a list of what was found).
        const picker = sheet(t.win, "picked", x => x.found === undefined);
        picker.open();
        picker.close();
        compare(t.win.activeFocusItem, inSheet);
        sources.close();
    }
}
