import QtQuick
import QtTest
import "../../apps/settings/qml/MouseTrackpad.js" as MT
import "../../apps/settings/qml" as SettingsQml

// GF-066: the Grassfield-owned Mouse and Trackpad file (apps/settings/qml/MouseTrackpad.js) and the panes that write it; the
// pointing devices of /proc/bus/input/devices (which pane the sidebar shows), Tracking speed's stops and the gestures drawn.
TestCase {
    id: testCase
    name: "MouseTrackpad"
    width: 700
    height: 900
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        QtObject {
            property string configFile: "/cfg/grassfield.json"
            property var files: ({})
            property var writes: []
            property string failure: ""
            function readText(path: string): var {
                return path in files ? {exists: true, ok: true, text: files[path]} : {exists: false, ok: false, text: ""};
            }
            function writeText(path: string, text: string): string {
                writes.push({path: path, text: text});
                if (failure === "")
                    files[path] = text;
                return failure;
            }
        }
    }

    function test_defaults() {
        compare(MT.parse("").sensitivity, 0);
        compare(MT.parse("").natural_scroll, true);
        compare(MT.parse("").mouse_natural_scroll, false);
        compare(MT.parse("").tap_to_click, true);
        compare(MT.parse("").secondary_click, "two_finger");
        compare(MT.parse(undefined).secondary_click, "two_finger");
    }

    function test_roundtrip() {
        const s = {sensitivity: -0.35, natural_scroll: false, mouse_natural_scroll: true, tap_to_click: false, secondary_click: "corner"};
        const text = MT.serialize(s);
        verify(text.indexOf("return {") >= 0);
        const back = MT.parse(text);
        compare(back.sensitivity, -0.35);
        compare(back.natural_scroll, false);
        compare(back.mouse_natural_scroll, true);
        compare(back.tap_to_click, false);
        compare(back.secondary_click, "corner");
    }

    function test_invalid_values_are_ignored() {
        const text = "return {\n  sensitivity = 7,\n  natural_scroll = \"yes\",\n  tap_to_click = false,\n  secondary_click = \"left\",\n}\n";
        const s = MT.parse(text);
        compare(s.sensitivity, 0);
        compare(s.natural_scroll, true);
        compare(s.tap_to_click, false);
        compare(s.secondary_click, "two_finger");
        // The writer never emits what the reader refuses, whatever it is handed.
        const clean = MT.parse(MT.serialize({sensitivity: 9, secondary_click: "x", natural_scroll: 1}));
        compare(clean.sensitivity, 0);
        compare(clean.secondary_click, "two_finger");
        verify(MT.serialize({sensitivity: NaN}).indexOf("NaN") < 0);
    }

    function test_with_validates_one_key() {
        const base = MT.defaults();
        compare(MT.with_(base, "sensitivity", 0.5).sensitivity, 0.5);
        compare(MT.with_(base, "sensitivity", 0.1666).sensitivity, 0.17);
        compare(MT.with_(base, "sensitivity", 3).sensitivity, 1);
        compare(MT.with_(base, "sensitivity", "fast").sensitivity, 0);
        compare(MT.with_(base, "tap_to_click", false).tap_to_click, false);
        compare(MT.with_(base, "tap_to_click", "no").tap_to_click, true);
        compare(MT.with_(base, "secondary_click", "corner").secondary_click, "corner");
        compare(MT.with_(base, "secondary_click", "left").secondary_click, "two_finger");
        compare(MT.with_(base, "bogus", 1).bogus, undefined);
        // Hundredths, no floating point tails in the file.
        verify(MT.serialize(MT.with_(base, "sensitivity", 0.1 + 0.2)).indexOf("sensitivity = 0.3,") >= 0);
    }

    function test_page_writes_the_owned_file_next_to_grassfield_json() {
        const backend = createTemporaryObject(fakeBackend, testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/MousePage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, width: 700, height: 900});
        compare(page.path, "/cfg/mouse-trackpad.lua");
        compare(page.title, "Mouse");
        compare(page.settings.tap_to_click, true);
        page.change("tap_to_click", false);
        compare(backend.writes.length, 1);
        compare(backend.writes[0].path, "/cfg/mouse-trackpad.lua");
        compare(MT.parse(backend.writes[0].text).tap_to_click, false);
        compare(page.settings.tap_to_click, false);
        // A failed write keeps the old value and says why.
        backend.failure = "disk full";
        page.change("natural_scroll", false);
        compare(page.settings.natural_scroll, true);
        compare(page.writeError, "disk full");
    }

    function test_page_reads_an_existing_file() {
        const backend = createTemporaryObject(fakeBackend, testCase, {files: {"/cfg/mouse-trackpad.lua": MT.serialize({sensitivity: 0.25, secondary_click: "corner"})}});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/MousePage.qml"));
        const page = createTemporaryObject(comp, testCase, {backend: backend, width: 700, height: 900});
        compare(page.settings.sensitivity, 0.25);
        compare(page.settings.secondary_click, "corner");
    }
    // A device block of /proc/bus/input/devices.
    function device(bus: string, vendor: string, product: string, name: string, handlers: string, bits: var): string {
        let text = "I: Bus=" + bus + " Vendor=" + vendor + " Product=" + product + " Version=0100\nN: Name=\"" + name + "\"\nH: Handlers=" + handlers + " \n";
        for (const k of Object.keys(bits))
            text += "B: " + k + "=" + bits[k] + "\n";
        return text;
    }

    function test_pointers() {
        const lid = device("0019", "0000", "0005", "Lid Switch", "event0", {PROP: "0", EV: "21", SW: "1"});
        const keyboard = device("0011", "0001", "0001", "AT Translated Set 2 keyboard", "sysrq kbd event3 leds", {PROP: "0", EV: "120013", KEY: "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe"});
        // An I2C touchpad and its own mouse node (the same identity).
        const touchpad = device("0018", "0F1E", "0101", "GF Touchpad", "mouse1 event8", {PROP: "5", EV: "1b", KEY: "e520 10000 0 0 0 0", ABS: "2e0800000000003"});
        const touchpadMouse = device("0018", "0F1E", "0101", "GF Mouse", "mouse0 event7", {PROP: "0", EV: "17", KEY: "30000 0 0 0 0", REL: "3"});
        const usbMouse = device("0003", "3c52", "0001", "USB Mouse", "mouse2 event9", {PROP: "0", EV: "17", KEY: "1f0000 0 0 0 0", REL: "1943"});
        const btMouse = device("0005", "3c52", "0002", "BT Mouse", "mouse3 event10", {PROP: "0", EV: "17", KEY: "70000 0 0 0 0", REL: "903"});
        const trackpoint = device("0011", "0002", "000a", "TPPS/2 IBM TrackPoint", "mouse4 event11", {PROP: "21", EV: "7", KEY: "70000 0 0 0 0", REL: "3"});
        const touchscreen = device("0018", "04f3", "2c4e", "Touchscreen", "mouse5 event12", {PROP: "2", EV: "b", KEY: "400 0 0 0 0 0", ABS: "3273800000000003"});
        const pen = device("0003", "056a", "0357", "Pen Tablet", "mouse6 event13", {PROP: "1", EV: "1b", KEY: "1c63 0 0 0 0 0", ABS: "3000003"});
        // A USB touchpad with a mouse node of its own; a mouse whose node is not a pointer (no mouseN handler) is not counted.
        const usbTouchpad = device("0003", "05ac", "0265", "USB Touchpad", "mouse7 event14", {PROP: "5", EV: "1b", KEY: "e520 10000 0 0 0 0", ABS: "2e0800000000003"});
        const usbTouchpadMouse = device("0003", "05ac", "0265", "USB Touchpad Mouse", "mouse8 event15", {PROP: "0", EV: "17", KEY: "70000 0 0 0 0", REL: "3"});
        const notPointer = device("0003", "3c52", "0003", "Keyboard Mouse", "kbd event16", {PROP: "0", EV: "17", KEY: "70000 0 0 0 0", REL: "3"});
        const all = list => list.join("\n");
        compare(MT.pointers(""), {mouse: false, touchpad: false});
        compare(MT.pointers(undefined), {mouse: false, touchpad: false});
        compare(MT.pointers(all([lid, keyboard, touchpad, touchpadMouse])), {mouse: false, touchpad: true});
        compare(MT.pointers(all([lid, keyboard, touchpad, touchpadMouse, usbMouse])), {mouse: true, touchpad: true});
        compare(MT.pointers(all([keyboard, btMouse])), {mouse: true, touchpad: false});
        compare(MT.pointers(all([keyboard, trackpoint, touchscreen, pen])), {mouse: false, touchpad: false});
        compare(MT.pointers(all([usbTouchpad, usbTouchpadMouse])), {mouse: false, touchpad: true});
        compare(MT.pointers(all([notPointer])), {mouse: false, touchpad: false});
        // The bitmaps: 64-bit words, the most significant first; a missing word is zero.
        verify(MT.bit(["e520", "10000", "0", "0", "0", "0"], 0x145));
        verify(MT.bit(["e520", "10000", "0", "0", "0", "0"], 0x110));
        verify(!MT.bit(["e520", "10000", "0", "0", "0", "0"], 0x140));
        verify(!MT.bit(["3"], 64));
        verify(!MT.bit([], 0));
    }

    function test_paneFor() {
        compare(MT.paneFor("mouse", {mouse: false, touchpad: true}), "trackpad");
        compare(MT.paneFor("trackpad", {mouse: true, touchpad: false}), "mouse");
        compare(MT.paneFor("mouse", {mouse: true, touchpad: true}), "mouse");
        // Neither there: the pane asked for (its choices apply when a device comes).
        compare(MT.paneFor("trackpad", {mouse: false, touchpad: false}), "trackpad");
        compare(MT.paneFor("sound", {mouse: false, touchpad: true}), "sound");
    }

    function test_trackingStops() {
        compare(MT.TRACKING.length, 10);
        // The session's 0 is the fourth stop, as macOS's default.
        compare(MT.TRACKING[MT.trackingIndex(0)], 0);
        compare(MT.trackingIndex(0), 3);
        compare(MT.trackingIndex(-1), 0);
        compare(MT.trackingIndex(1), 9);
        // A value between stops (an older file, a hand-written one) shows at the nearest.
        compare(MT.trackingIndex(0.3), 5);
        compare(MT.trackingIndex(-0.6), 1);
        // Every stop survives the file.
        for (const v of MT.TRACKING)
            compare(MT.parse(MT.serialize(MT.with_(MT.defaults(), "sensitivity", v))).sensitivity, v);
    }

    function test_gestures() {
        // At rest, the fingers where the gesture starts; a swipe moves them all the same way.
        compare(MT.fingersAt("tap", 0), [[0.5, 0.5]]);
        compare(MT.fingersAt("tap", 1), [[0.5, 0.5]]);
        verify(MT.presses("tap"));
        verify(!MT.presses("spaces"));
        const start = MT.fingersAt("spaces", 0), end = MT.fingersAt("spaces", 1);
        compare(start.length, 3);
        for (let i = 0; i < 3; i++) {
            fuzzyCompare(end[i][0] - start[i][0], 0.24, 1e-9);
            fuzzyCompare(end[i][1] - start[i][1], 0, 1e-9);
        }
        // A pinch brings the four fingers towards their centre.
        const open = MT.fingersAt("apps", 0), closed = MT.fingersAt("apps", 1);
        compare(open.length, 4);
        const spread = list => Math.max(...list.map(f => f[0])) - Math.min(...list.map(f => f[0]));
        verify(spread(closed) < spread(open) * 0.5);
        // Every gesture stays on the drawing.
        for (const g of Object.keys(MT.GESTURES)) {
            for (const t of [0, 0.5, 1]) {
                for (const f of MT.fingersAt(g, t))
                    verify(f[0] > 0 && f[0] < 1 && f[1] > 0 && f[1] < 1, g + " at " + t);
            }
        }
        compare(MT.fingersAt("nothing", 0), []);
    }

    function test_trackpadPane() {
        const backend = createTemporaryObject(fakeBackend, testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/TrackpadPage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, width: 700, height: 900});
        compare(page.title, "Trackpad");
        // Each tab shows its first row's gesture until a row is under the pointer or holds the focus.
        compare(page.gesture, "tracking");
        page.tab = "scroll";
        compare(page.gesture, "scroll");
        page.tab = "more";
        compare(page.gesture, "spaces");
        page.show("apps", true);
        compare(page.gesture, "apps");
        // Another row leaving does not hide the one shown; the shown one leaving does.
        page.show("overview", false);
        compare(page.gesture, "apps");
        page.show("apps", false);
        compare(page.gesture, "spaces");
        // The gestures' switches write their keys; every pane writes the one shared file.
        page.change("gesture_overview", false);
        compare(backend.writes[0].path, "/cfg/mouse-trackpad.lua");
        compare(MT.parse(backend.writes[0].text).gesture_overview, false);
        page.change("sensitivity", MT.TRACKING[6]);
        compare(MT.parse(backend.writes[1].text).sensitivity, 0.5);
        compare(MT.parse(backend.writes[1].text).gesture_overview, false);
        // Set Up Bluetooth Trackpad… asks Main.qml for Bluetooth.
        const opened = [];
        page.openRequested.connect(id => opened.push(id));
        page.openRequested("bluetooth");
        compare(opened, ["bluetooth"]);
    }

    Component {
        id: rowHost
        Column {
            width: 468
            property alias first: first
            property alias second: second
            property alias third: third
            property var shown: []
            SettingsQml.GestureRow {
                id: first
                title: "Tracking speed"
                rowHeight: 50
                gesture: "tracking"
                onShowing: (g, on) => parent.shown.push([g, on])
            }
            SettingsQml.GestureRow {
                id: second
                title: "Secondary click"
                gesture: "secondary"
                onShowing: (g, on) => parent.shown.push([g, on])
            }
            SettingsQml.GestureRow {
                id: third
                title: "Tap to click"
                subtitle: "Tap with one finger"
                gesture: "tap"
                onShowing: (g, on) => parent.shown.push([g, on])
            }
        }
    }

    function test_gestureRows() {
        const host = createTemporaryObject(rowHost, testCase);
        // The first row has no separator above it; the others one each (macOS 27 pitches 50, 37 + 1, 52 + 1).
        compare(host.first.height, 50);
        compare(host.second.height, 38);
        compare(host.third.height, 53);
        verify(host.first.first && !host.first.last);
        verify(host.third.last);
        // The pointer over a row shows its gesture; moving to the next hands over.
        mouseMove(host, 100, 60);
        tryCompare(host.second, "active", true);
        mouseMove(host, 100, 120);
        tryCompare(host.third, "active", true);
        verify(!host.second.active);
        // The leave and the enter may come in either order.
        compare(host.shown.length, 3);
        compare(host.shown[0], ["secondary", true]);
        verify(host.shown.some(e => e[0] === "secondary" && !e[1]) && host.shown.some(e => e[0] === "tap" && e[1]));
    }
}
