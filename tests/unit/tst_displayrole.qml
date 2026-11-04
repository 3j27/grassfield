import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// The main display (ADR-0044, ui/Grassfield/Ui/DisplayRole.js): identity, the choice per set of displays, the fallback
// when the main display is gone, validation of the stored list, and the settings contract's rule for `displays.main`.
TestCase {
    name: "DisplayRole"

    readonly property var panel: ({name: "eDP-1", make: "LG", model: "LGD", serial: "123"})
    readonly property var desk: ({name: "DP-2", make: "Dell", model: "DELL U2723", serial: "ABC"})
    readonly property var deskMoved: ({name: "HDMI-A-1", make: "Dell", model: "DELL U2723", serial: "ABC"})
    readonly property var tv: ({name: "HDMI-A-2", make: "Acme", model: "TV", serial: ""})
    readonly property var twinA: ({name: "DP-1", make: "Acme", model: "ACME", serial: ""})
    readonly property var twinB: ({name: "DP-3", make: "Acme", model: "ACME", serial: ""})
    readonly property var virtual: ({name: "GF-REF", model: "", serial: ""})

    function test_identity() {
        compare(DisplayRole.identity(panel), "s:LG|LGD|123");
        // The same panel on another port is the same display.
        compare(DisplayRole.identity(deskMoved), DisplayRole.identity(desk));
        // No serial: the model with the connector, so identical monitors stay apart.
        verify(DisplayRole.identity(twinA) !== DisplayRole.identity(twinB));
        // No EDID at all: the connector name alone.
        compare(DisplayRole.identity(virtual), "n:GF-REF");
        compare(DisplayRole.identity(null), "n:");
    }

    // Hyprland's monitors answer is the identity's source (Qt's screens have no serial): connected() joins it to the outputs.
    function test_connectedJoinsHyprlandsAnswer() {
        const described = [{name: "eDP-1", make: "LG", model: "LGD", serial: "123"}, {name: "DP-2", make: "Dell", model: "DELL U2723", serial: "ABC"}];
        let c = DisplayRole.connected(["DP-2", "eDP-1"], described);
        verify(c.ready);
        compare(c.displays[0], {name: "DP-2", make: "Dell", model: "DELL U2723", serial: "ABC"});
        compare(DisplayRole.identity(c.displays[0]), DisplayRole.identity(desk));
        // An output Hyprland has not described yet: not ready, keyed by its connector.
        c = DisplayRole.connected(["eDP-1", "HDMI-A-1"], described);
        verify(!c.ready);
        compare(DisplayRole.identity(c.displays[1]), "n:HDMI-A-1");
        verify(!DisplayRole.connected([], described).ready);
        verify(!DisplayRole.connected(["eDP-1"], null).ready);
    }

    // The setting is read after the shell and the Dock exist: the fallback until the main display is known, then the stored
    // choice (what the Dock latches on, Geometry.latchScreenWhen, is tested in tst_dockgeometry).
    function test_choiceReadAfterTheDisplaysAreKnown() {
        const described = [{name: "eDP-1", make: "LG", model: "LGD", serial: "123"}, {name: "DP-2", make: "Dell", model: "DELL U2723", serial: "ABC"}];
        const live = DisplayRole.connected(["eDP-1", "DP-2"], described).displays;
        compare(DisplayRole.resolve([], live).name, "eDP-1");
        const stored = DisplayRole.withMain([], live, DisplayRole.identity(desk));
        compare(DisplayRole.resolve(stored, live).name, "DP-2");
    }

    function test_setIsOrderFree() {
        compare(DisplayRole.setOf([panel, desk]), DisplayRole.setOf([desk, panel]));
        compare(DisplayRole.setOf([panel, desk]), DisplayRole.setOf([panel, deskMoved]));
    }

    function test_defaultIsTheBuiltinPanel() {
        const r = DisplayRole.resolve([], [desk, panel]);
        compare(r.name, "eDP-1");
        compare(r.why, "builtin");
    }

    function test_defaultWithoutBuiltinIsTheFirst() {
        const r = DisplayRole.resolve([], [desk, tv]);
        compare(r.name, "DP-2");
        compare(r.why, "first");
        compare(DisplayRole.resolve([], []).why, "none");
        compare(DisplayRole.resolve([], []).name, "");
    }

    function test_choiceForTheSet() {
        const entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        const r = DisplayRole.resolve(entries, [panel, desk]);
        compare(r.name, "DP-2");
        compare(r.why, "chosen");
        // Whatever the order the compositor lists them in.
        compare(DisplayRole.resolve(entries, [desk, panel]).name, "DP-2");
    }

    function test_choiceFollowsTheDisplayToAnotherPort() {
        const entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        const r = DisplayRole.resolve(entries, [panel, deskMoved]);
        compare(r.name, "HDMI-A-1");
        compare(r.why, "chosen");
    }

    function test_mainUnpluggedFallsBackToTheBuiltin() {
        const entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        const r = DisplayRole.resolve(entries, [panel]);
        compare(r.name, "eDP-1");
        compare(r.why, "builtin");
        // No built-in panel: the first one.
        const e2 = DisplayRole.withMain([], [desk, tv], DisplayRole.identity(tv));
        const r2 = DisplayRole.resolve(e2, [desk]);
        compare(r2.name, "DP-2");
        compare(r2.why, "first");
    }

    function test_choiceComesBackWhenTheSetDoes() {
        let entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        compare(DisplayRole.resolve(entries, [panel]).name, "eDP-1");
        compare(DisplayRole.resolve(entries, [panel, desk]).name, "DP-2");
    }

    function test_aDisplayPluggedInDoesNotMoveTheMain() {
        const entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        const r = DisplayRole.resolve(entries, [panel, desk, tv]);
        compare(r.name, "DP-2");
        compare(r.why, "remembered");
    }

    function test_theChoiceOfAnotherSetDoesNotWinOverThisSetsOwn() {
        let entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        entries = DisplayRole.withMain(entries, [panel, desk, tv], DisplayRole.identity(tv));
        compare(DisplayRole.resolve(entries, [panel, desk, tv]).name, "HDMI-A-2");
        compare(DisplayRole.resolve(entries, [panel, desk]).name, "DP-2");
        compare(DisplayRole.resolve(entries, [panel, desk]).why, "chosen");
    }

    function test_twinsWithoutSerialAreTold() {
        const entries = DisplayRole.withMain([], [twinA, twinB], DisplayRole.identity(twinB));
        compare(DisplayRole.resolve(entries, [twinA, twinB]).name, "DP-3");
    }

    function test_withMainReplacesTheSetsEntryAndPutsItFirst() {
        let entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        entries = DisplayRole.withMain(entries, [panel], DisplayRole.identity(panel));
        compare(entries.length, 2);
        entries = DisplayRole.withMain(entries, [panel, desk], DisplayRole.identity(panel));
        compare(entries.length, 2);
        compare(entries[0].main, DisplayRole.identity(panel));
        compare(entries[0].set.length, 2);
    }

    function test_withMainRefusesAStrangerAndKeepsAtMostSixteen() {
        const before = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        compare(DisplayRole.withMain(before, [panel, desk], "s:Other|1"), before);
        let entries = [];
        for (let i = 0; i < 20; i++) {
            const d = {name: "DP-" + i, model: "M", serial: "S" + i};
            entries = DisplayRole.withMain(entries, [panel, d], DisplayRole.identity(d));
        }
        compare(entries.length, DisplayRole.MAX_ENTRIES);
        compare(DisplayRole.problem(entries), "");
        // The newest is first.
        compare(entries[0].main, "s:|M|S19");
    }

    function test_validation() {
        const ok = [{set: ["s:LG|LGD|123", "s:M|1"], main: "s:M|1"}];
        compare(DisplayRole.problem([]), "");
        compare(DisplayRole.problem(ok), "");
        verify(DisplayRole.problem("x") !== "");
        verify(DisplayRole.problem({}) !== "");
        verify(DisplayRole.problem([{set: ["s:M|1"], main: "s:Z|9"}]) !== "");
        verify(DisplayRole.problem([{set: ["s:M|1", "s:LG|LGD|123"], main: "s:M|1"}]) !== "", "unsorted set");
        verify(DisplayRole.problem([{set: ["s:M|1", "s:M|1"], main: "s:M|1"}]) !== "", "repeated key");
        verify(DisplayRole.problem([{set: [], main: ""}]) !== "");
        verify(DisplayRole.problem([{set: ["s:M|1"], main: "s:M|1", extra: 1}]) !== "");
        verify(DisplayRole.problem([{set: ["s:M|\u0001"], main: "s:M|\u0001"}]) !== "");
        verify(DisplayRole.problem([ok[0], ok[0]]) !== "", "the same set twice");
        const many = [];
        for (let i = 0; i < 17; i++)
            many.push({set: ["s:M|" + i], main: "s:M|" + i});
        compare(DisplayRole.problem(many), "too-many");
    }

    function test_normalizeKeepsTheGoodEntries() {
        const good = {set: ["s:A|1", "s:B|2"], main: "s:B|2"};
        const list = [{bad: true}, good, good, {set: ["s:C|3"], main: "s:Z|0"}];
        const out = DisplayRole.normalize(list);
        compare(out.length, 1);
        compare(out[0].main, "s:B|2");
        compare(DisplayRole.normalize("nope").length, 0);
        compare(DisplayRole.normalize(null).length, 0);
        // A copy, never the stored object.
        verify(out[0] !== good);
    }

    function test_aBadStoredListReadsAsTheDefaultChoice() {
        const r = DisplayRole.resolve("garbage", [desk, panel]);
        compare(r.name, "eDP-1");
        compare(r.why, "builtin");
    }

    // The Settings store writes the choice into grassfield.json beside the other keys and reads it back (the keys it does not
    // know are kept: a wallpaper override survives).
    function test_storeRoundTrip() {
        const entries = DisplayRole.withMain([], [panel, desk], DisplayRole.identity(desk));
        const start = '{"version":1,"appearance":"light","wallpaper":{"outputs":[{"display":{"name":"DP-2","model":"DELL U2723","serial":"ABC"},"fit":"tile"}]}}';
        const w = Store.setValue(start, "displays.main", entries);
        verify(w.ok, w.error);
        const data = JSON.parse(w.text);
        compare(data.appearance, "light");
        compare(data.wallpaper.outputs.length, 1);
        compare(data.displays.main, entries);
        compare(Store.read(data, "displays.main"), entries);
        // A hand-edited bad list reads as no choice; a write of one is refused.
        compare(Store.read({displays: {main: "x"}}, "displays.main"), []);
        verify(!Store.setValue(start, "displays.main", [{set: ["s:A|1"], main: "s:B|2"}]).ok);
        // A file from before the key reads as the default.
        compare(Store.read(JSON.parse(start), "displays.main"), []);
    }

    // The settings contract: the key exists, is empty by default, and a write is validated by this module.
    function test_contract() {
        compare(SettingsContract.DEFAULTS["displays.main"], []);
        compare(SettingsContract.validate("displays.main", []), "");
        compare(SettingsContract.validate("displays.main", [{set: ["s:M|1"], main: "s:M|1"}]), "");
        verify(SettingsContract.validate("displays.main", [{set: ["s:M|1"], main: "s:X|1"}]) !== "");
        verify(SettingsContract.validate("displays.main", "x") !== "");
        compare(SettingsContract.read({displays: {main: [{set: ["s:M|1"], main: "s:Q|1"}]}}, "displays.main"), []);
    }
}
