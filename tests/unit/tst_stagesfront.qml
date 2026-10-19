import QtQuick
import QtTest
import "../../shell/platform/StagesFront.js" as StagesFront

// Front app of the Stages event for the menu bar (docs/specs/stages.md "Event contract" 4, docs/specs/menubar.md):
// the selection rules and the untrusted-text handling. Test names state the user-visible rule.
TestCase {
    name: "StagesFront"

    function ev(on, front, monitor) {
        const mon = {monitor: monitor || "GF-REF", workspace: 1, active: 5, stages: []};
        if (front !== undefined)
            mon.front = front;
        return JSON.stringify({v: "gfc/1", type: "stages", on: on, monitors: [mon]});
    }

    readonly property var front: ({address: "55d0c8a3b2f0", app: "gf-stage-b"})

    function pick(data, active, plugin, monitor, live) {
        return StagesFront.select(StagesFront.parse(data), active, plugin, monitor, live);
    }

    function test_anActiveWindowWins() {
        compare(pick(ev(true, front), true, true, "GF-REF", ["55d0c8a3b2f0"]), "");
    }

    function test_noActiveWindowNamesTheStagesFront() {
        compare(pick(ev(true, front), false, true, "GF-REF", ["55d0c8a3b2f0"]), "gf-stage-b");
    }

    function test_theFrontWindowGoneNamesNothing() {
        compare(pick(ev(true, front), false, true, "GF-REF", ["1234"]), "");
        compare(pick(ev(true, front), false, true, "GF-REF", []), "");
    }

    function test_stagesOffNamesNothing() {
        compare(pick(ev(false, front), false, true, "GF-REF", ["55d0c8a3b2f0"]), "");
    }

    function test_noEventYetOrAnEventWithoutFrontNamesNothing() {
        compare(StagesFront.select(null, false, true, "GF-REF", ["55d0c8a3b2f0"]), "");
        compare(pick(ev(true, undefined), false, true, "GF-REF", ["55d0c8a3b2f0"]), "");
    }

    function test_aGonePluginNamesNothing() {
        compare(pick(ev(true, front), false, false, "GF-REF", ["55d0c8a3b2f0"]), "");
    }

    function test_theFocusedOutputsFrontIsUsed() {
        const data = JSON.stringify({v: "gfc/1", type: "stages", on: true, monitors: [
            {monitor: "A", front: {address: "aa", app: "one"}},
            {monitor: "B", front: {address: "bb", app: "two"}}]});
        compare(pick(data, false, true, "B", ["aa", "bb"]), "two");
        compare(pick(data, false, true, "A", ["aa", "bb"]), "one");
        compare(pick(data, false, true, "", ["aa", "bb"]), "one");
        compare(pick(data, false, true, "B", ["aa"]), "");
    }

    function test_addressesCompareWithOrWithoutPrefixAndCase() {
        compare(pick(ev(true, {address: "0x55D0C8A3B2F0", app: "x"}), false, true, "GF-REF", ["55d0c8a3b2f0"]), "x");
        compare(pick(ev(true, front), false, true, "GF-REF", ["0x55D0C8A3B2F0"]), "gf-stage-b");
    }

    function test_clientTextIsPlainAndCapped() {
        const nasty = "ev\u0000il\n\u202eapp\u001b[31m";
        compare(pick(ev(true, {address: "aa", app: nasty}), false, true, "GF-REF", ["aa"]), "evilapp[31m");
        const long = StagesFront.parse(ev(true, {address: "aa", app: "a".repeat(1000)})).fronts[0].app;
        compare(long.length, 128);
        compare(StagesFront.parse(ev(true, {address: "zz", app: "x"})).fronts.length, 0);
        compare(StagesFront.parse(ev(true, {address: "aa", app: 5})).fronts.length, 0);
        compare(StagesFront.parse(ev(true, {address: "aa", app: " \n "})).fronts.length, 0);
    }

    function test_otherPayloadsAreNotStagesEvents() {
        compare(StagesFront.parse("not json"), null);
        compare(StagesFront.parse('{"v":"gfc/1","type":"capabilities","features":[]}'), null);
        compare(StagesFront.parse('{"v":"gfc/2","type":"stages","on":true,"monitors":[]}'), null);
        compare(StagesFront.parse("null"), null);
    }
}
