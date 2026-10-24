import QtQuick
import QtTest
import "../../shell/services/ScreenChoice.js" as ScreenChoice

// A screen is a name that is looked up in the live list each time it is used: unplugging one never leaves UI on it.
TestCase {
    name: "ScreenChoice"

    function test_aLiveScreenKeepsItsName() {
        compare(ScreenChoice.resolve("DP-2", ["DP-1", "DP-2"]), "DP-2");
        verify(!ScreenChoice.gone("DP-2", ["DP-1", "DP-2"]));
    }

    function test_aRemovedScreenFallsBackToTheFirstLiveOne() {
        compare(ScreenChoice.resolve("DP-2", ["DP-1"]), "DP-1");
        compare(ScreenChoice.resolve("DP-1", ["DP-3", "DP-1"]), "DP-1");
        compare(ScreenChoice.resolve("DP-9", ["DP-3", "DP-1"]), "DP-3");
        verify(ScreenChoice.gone("DP-2", ["DP-1"]));
    }

    function test_noNameOrNoScreenAtAll() {
        compare(ScreenChoice.resolve("", ["DP-1"]), "DP-1");
        compare(ScreenChoice.resolve(undefined, ["DP-1"]), "DP-1");
        compare(ScreenChoice.resolve("DP-1", []), "");
        compare(ScreenChoice.resolve("DP-1", undefined), "");
        verify(!ScreenChoice.gone("", ["DP-1"]), "no name is not a removed screen");
        verify(ScreenChoice.gone("DP-1", []), "the last screen going away");
        verify(!ScreenChoice.gone(null, []));
    }
}
