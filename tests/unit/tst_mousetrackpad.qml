import QtQuick
import QtTest
import "../../apps/settings/qml/MouseTrackpad.js" as MT

// GF-066: the Grassfield-owned Mouse & Trackpad file (apps/settings/qml/MouseTrackpad.js) and the page that writes it.
TestCase {
    id: testCase
    name: "MouseTrackpad"
    width: 700
    height: 900
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
        compare(MT.with_(base, "sensitivity", 3).sensitivity, 1);
        compare(MT.with_(base, "sensitivity", "fast").sensitivity, 0);
        compare(MT.with_(base, "tap_to_click", false).tap_to_click, false);
        compare(MT.with_(base, "tap_to_click", "no").tap_to_click, true);
        compare(MT.with_(base, "secondary_click", "corner").secondary_click, "corner");
        compare(MT.with_(base, "secondary_click", "left").secondary_click, "two_finger");
        compare(MT.with_(base, "bogus", 1).bogus, undefined);
        // Steps of 0.05, no floating point tails in the file.
        verify(MT.serialize(MT.with_(base, "sensitivity", 0.1 + 0.2)).indexOf("sensitivity = 0.3,") >= 0);
    }

    function test_page_writes_the_owned_file_next_to_grassfield_json() {
        const backend = createTemporaryObject(fakeBackend, testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/MousePage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, width: 700, height: 900});
        compare(page.path, "/cfg/mouse-trackpad.lua");
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
}
