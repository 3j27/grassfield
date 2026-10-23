import QtQuick
import QtTest
import "../../shell/platform/Zoom.js" as Zoom

// Screen magnification (GF-064): the factor the compositor gets and the Lua request that carries it.
TestCase {
    name: "Zoom"

    function test_factorIsOneWhileOff() {
        compare(Zoom.factor(false, 3), 1);
        compare(Zoom.factor(undefined, 3), 1);
        compare(Zoom.factor(true, 3), 3);
    }

    function test_levelIsClampedAndSnapped() {
        compare(Zoom.clampLevel(1), 1.5);
        compare(Zoom.clampLevel(9), 5);
        compare(Zoom.clampLevel(2.3), 2.5);
        compare(Zoom.clampLevel("x"), 2);
        compare(Zoom.clampLevel(NaN), 2);
    }

    function test_stepsStopAtTheEnds() {
        compare(Zoom.step(2, 1), 2.5);
        compare(Zoom.step(2, -1), 1.5);
        compare(Zoom.step(1.5, -1), 1.5);
        compare(Zoom.step(5, 1), 5);
    }

    function test_requestIsALuaFunctionWithAPlainNumber() {
        compare(Zoom.request(2), "function() pcall(hl.config, { cursor = { zoom_factor = 2.00 } }) end");
        compare(Zoom.request(1), "function() pcall(hl.config, { cursor = { zoom_factor = 1.00 } }) end");
    }

    function test_requestRefusesAnythingElse() {
        compare(Zoom.request(0.5), "");
        compare(Zoom.request(6), "");
        compare(Zoom.request("2); os.execute('x'"), "");
        compare(Zoom.request(NaN), "");
        compare(Zoom.request(undefined), "");
    }
}
