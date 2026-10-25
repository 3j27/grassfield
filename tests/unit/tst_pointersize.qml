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

    function test_fromStored() {
        // A number is rounded and clamped, like every reader of the contract (ADR-0020): an off-step integer is kept.
        compare(PointerSize.fromStored(24), 24);
        compare(PointerSize.fromStored(48), 48);
        compare(PointerSize.fromStored(51), 51);
        compare(PointerSize.fromStored(51.5), 52);
        compare(PointerSize.fromStored(60.5), 61);
        compare(PointerSize.fromStored(96), 96);
        compare(PointerSize.fromStored(23), 24);
        compare(PointerSize.fromStored(97), 96);
        compare(PointerSize.fromStored(200), 96);
        compare(PointerSize.fromStored(1000), 96);
        compare(PointerSize.fromStored(-48), 24);
        // Anything that is not a finite number is the default, never parsed.
        const bad = ["64", "x", true, null, undefined, NaN, Infinity, [48], {}];
        for (const v of bad)
            compare(PointerSize.fromStored(v), 24, "fromStored(" + JSON.stringify(v) + ")");
    }

    function test_launchEnvironment() {
        compare(PointerSize.launchEnvironment(24, 24), {});
        compare(PointerSize.launchEnvironment(48, 48), {});
        compare(PointerSize.launchEnvironment(48, 24), {"XCURSOR_SIZE": "48", "HYPRCURSOR_SIZE": "48"});
        compare(PointerSize.launchEnvironment(24, 48), {"XCURSOR_SIZE": "24", "HYPRCURSOR_SIZE": "24"});
        compare(PointerSize.launchEnvironment(51.5, 24), {});
        compare(PointerSize.launchEnvironment("48", 24), {});
    }

    function test_retryDelay() {
        compare(PointerSize.retryDelay(250, 1), 250);
        compare(PointerSize.retryDelay(250, 2), 500);
        compare(PointerSize.retryDelay(250, 4), 2000);
        compare(PointerSize.retryDelay(250, 0), 250);
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
