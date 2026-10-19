import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Pointer size (Settings > Accessibility > Pointer, ADR-0014): range, snapping, XCursor sizes, the compositor request,
// and the settings rules (the schema parity lives in tst_settingsstore).
TestCase {
    name: "PointerSize"

    function test_bounds() {
        compare(PointerSize.MIN, 24);
        compare(PointerSize.MAX, 96);
        compare(PointerSize.DEFAULT, 24);
        compare((PointerSize.MAX - PointerSize.MIN) % PointerSize.STEP, 0);
    }

    function test_normalize() {
        compare(PointerSize.normalize(24), 24);
        compare(PointerSize.normalize(96), 96);
        compare(PointerSize.normalize(52), 52);
        // Invalid values are the default, never clamped silently.
        compare(PointerSize.normalize(23), 24);
        compare(PointerSize.normalize(97), 24);
        compare(PointerSize.normalize(30.5), 24);
        compare(PointerSize.normalize("48"), 24);
        compare(PointerSize.normalize(NaN), 24);
        compare(PointerSize.normalize(undefined), 24);
        compare(PointerSize.normalize(null), 24);
    }

    function test_snap() {
        compare(PointerSize.snap(24), 24);
        compare(PointerSize.snap(25.9), 24);
        compare(PointerSize.snap(26), 28);
        compare(PointerSize.snap(47), 48);
        compare(PointerSize.snap(96), 96);
        compare(PointerSize.snap(10), 24);
        compare(PointerSize.snap(500), 96);
        compare(PointerSize.snap(NaN), 24);
        compare(PointerSize.snap("x"), 24);
        // Every snapped value is storable.
        for (let v = -10; v < 140; v += 0.7)
            verify(PointerSize.valid(PointerSize.snap(v)), "snap(" + v + ")");
    }

    function test_xcursorSize() {
        const expected = {24: 24, 28: 24, 32: 32, 36: 32, 40: 32, 44: 48, 48: 48, 56: 48, 60: 64, 64: 64, 76: 64, 80: 64, 84: 96, 96: 96};
        for (const size in expected)
            compare(PointerSize.xcursorSize(Number(size)), expected[size], "size " + size);
        // Invalid input is the default size.
        compare(PointerSize.xcursorSize(5), 24);
        compare(PointerSize.xcursorSize("big"), 24);
    }

    function test_setCursorRequest() {
        compare(PointerSize.setCursorRequest("grassfield-cursors", 48), "/setcursor grassfield-cursors 48");
        compare(PointerSize.setCursorRequest("grassfield-cursors-custom", 24), "/setcursor grassfield-cursors-custom 24");
        // Anything that is not a plain theme name or a valid size is never forwarded to the compositor.
        compare(PointerSize.setCursorRequest("", 48), "");
        compare(PointerSize.setCursorRequest("a b", 48), "");
        compare(PointerSize.setCursorRequest("x\n/dispatch exit", 48), "");
        compare(PointerSize.setCursorRequest("../x", 48), "");
        compare(PointerSize.setCursorRequest(undefined, 48), "");
        compare(PointerSize.setCursorRequest("grassfield-cursors", 100), "");
        compare(PointerSize.setCursorRequest("grassfield-cursors", "48"), "");
    }

    function test_settingsRule() {
        compare(Store.DEFAULTS["pointer.size"], PointerSize.DEFAULT);
        compare(Store.RULES["pointer.size"].min, PointerSize.MIN);
        compare(Store.RULES["pointer.size"].max, PointerSize.MAX);
        compare(Store.validate("pointer.size", 24), "");
        compare(Store.validate("pointer.size", 96), "");
        verify(Store.validate("pointer.size", 23) !== "");
        verify(Store.validate("pointer.size", 97) !== "");
        verify(Store.validate("pointer.size", 30.5) !== "");
        verify(Store.validate("pointer.size", "48") !== "");
        const r = Store.setValue('{"version":1,"dock":{"pinned":["a"]}}', "pointer.size", 64);
        verify(r.ok);
        compare(JSON.parse(r.text), {version: 1, dock: {pinned: ["a"]}, pointer: {size: 64}});
        verify(!Store.setValue("{}", "pointer.size", 200).ok);
        compare(Store.read({pointer: {size: 7}}, "pointer.size"), 24);
        compare(Store.read({pointer: {size: 72}}, "pointer.size"), 72);
    }
}
