import QtQuick
import QtTest
import "../../apps/settings/qml/NavHistory.js" as Nav

// Back and forward through the Settings panes.
TestCase {
    name: "NavHistory"

    function test_visitBackForward() {
        let s = Nav.start("appearance");
        s = Nav.visit(s, "sound");
        s = Nav.visit(s, "wifi");
        compare(s.current, "wifi");
        compare(Nav.canBack(s), true);
        compare(Nav.canForward(s), false);
        s = Nav.back(s);
        compare(s.current, "sound");
        s = Nav.back(s);
        compare(s.current, "appearance");
        compare(Nav.canBack(s), false);
        s = Nav.forward(s);
        compare(s.current, "sound");
        compare(s.forward.join(), "wifi");
    }

    function test_aNewVisitForgetsTheForwardList() {
        let s = Nav.visit(Nav.visit(Nav.start("a"), "b"), "c");
        s = Nav.back(s);
        s = Nav.visit(s, "d");
        compare(s.current, "d");
        compare(Nav.canForward(s), false);
        compare(s.back.join(), "a,b");
    }

    function test_theSamePaneAndTheEndsChangeNothing() {
        const s = Nav.start("a");
        compare(Nav.visit(s, "a"), s);
        compare(Nav.back(s), s);
        compare(Nav.forward(s), s);
    }
}
