import QtQuick
import QtTest
import "../../shell/capture/CaptureModel.js" as Model

// The capture toolbar's decisions (ADR-0045 OC-1, docs/specs/system-dialogs.md "Capture toolbar"): the modes in macOS 27's
// order, the mode the toolbar opens in, the arrows, the helper's argv for every mode and option, the Options menu's rows and
// checks, and a chosen row as the setting it changes.
TestCase {
    name: "CaptureModel"

    readonly property var labels: ({
            saveTo: "Save to", desktop: "Desktop", documents: "Documents", clipboard: "Clipboard", preview: "Preview",
            timer: "Timer", none: "None", five: "5 Seconds", ten: "10 Seconds", microphone: "Microphone", micNone: "None",
            micDefault: "Built-in Microphone", options: "Options", showPointer: "Show Mouse Pointer"
        })

    function test_modesInOrder() {
        compare(Model.MODES.map(m => m.id), ["screen", "window", "selection", "recordScreen", "recordSelection"]);
        compare(Model.MODES.map(m => m.glyph), ["capture-screen", "capture-window", "capture-selection", "record-screen", "record-selection"]);
        compare(Model.shown(true).length, 5);
        compare(Model.shown(false).map(m => m.id), ["screen", "window", "selection"], "without the recorder, no Record buttons");
        verify(Model.isRecord("recordScreen") && Model.isRecord("recordSelection"));
        verify(!Model.isRecord("selection") && !Model.isRecord(""));
    }

    function test_startMode() {
        compare(Model.startMode("window", true), "window", "the mode chosen last");
        compare(Model.startMode("recordScreen", true), "recordScreen");
        compare(Model.startMode("recordScreen", false), "selection", "a recording that cannot start gives way");
        compare(Model.startMode("video", true), "selection", "an unknown mode: Capture Selected Portion");
        compare(Model.startMode(undefined, true), "selection");
    }

    function test_arrows() {
        compare(Model.step("selection", 1, true), "recordScreen");
        compare(Model.step("selection", -1, true), "window");
        compare(Model.step("screen", -1, true), "screen", "stops at the left end");
        compare(Model.step("recordSelection", 1, true), "recordSelection", "stops at the right end");
        compare(Model.step("selection", 1, false), "selection", "no recording to step to");
        compare(Model.step("recordScreen", 1, false), "screen", "a mode no longer offered: the first one");
    }

    function test_saveToPerMode() {
        compare(Model.saveTo("selection", "clipboard"), "clipboard");
        compare(Model.saveTo("recordScreen", "clipboard"), "desktop", "a movie is not copied");
        compare(Model.saveTo("recordScreen", "preview"), "preview");
        compare(Model.saveTo("screen", "mail"), "desktop");
        compare(Model.timerSeconds("5"), 5);
        compare(Model.timerSeconds("10"), 10);
        compare(Model.timerSeconds("none"), 0);
        compare(Model.timerSeconds(5), 0, "only the stored strings");
    }

    function test_helperArgs() {
        const plain = {saveTo: "desktop", timer: "none", microphone: "none", showPointer: false};
        compare(Model.helperArgs("screen", plain, "DP-1"), ["screen", "--save", "desktop"]);
        compare(Model.helperArgs("window", plain, "DP-1"), ["window", "--save", "desktop"]);
        compare(Model.helperArgs("selection", {saveTo: "clipboard", timer: "5", microphone: "default", showPointer: true}, "DP-1"),
            ["selection", "--save", "clipboard", "--timer", "5", "--pointer"], "no microphone for a screenshot");
        compare(Model.helperArgs("recordScreen", {saveTo: "documents", timer: "10", microphone: "default", showPointer: true}, "DP-1"),
            ["record", "screen", "--save", "documents", "--timer", "10", "--pointer", "--mic", "--output", "DP-1"]);
        compare(Model.helperArgs("recordSelection", {saveTo: "clipboard", timer: "none", microphone: "none", showPointer: false}, "DP-1"),
            ["record", "selection", "--save", "desktop"], "the area's display is the crosshair's; a movie goes to the Desktop");
        compare(Model.helperArgs("recordScreen", plain, "a b"), ["record", "screen", "--save", "desktop"], "an odd display name is not passed");
        compare(Model.helperArgs("recordScreen", plain, ""), ["record", "screen", "--save", "desktop"]);
        compare(Model.helperArgs("nope", null, ""), ["selection", "--save", "desktop"]);
    }

    function ids(rows) {
        return rows.map(r => r.separator ? "-" : (r.header ? "#" + r.text : r.id + (r.checked ? "*" : "")));
    }

    function test_menuForAScreenshot() {
        const rows = Model.menuModel("selection", {saveTo: "documents", timer: "5", microphone: "default", showPointer: false}, labels);
        compare(ids(rows), ["#Save to", "saveTo:desktop", "saveTo:documents*", "saveTo:clipboard", "saveTo:preview", "-",
            "#Timer", "timer:none", "timer:5*", "timer:10", "-", "#Options", "showPointer:toggle"]);
        compare(rows[8].text, "5 Seconds");
        verify(rows.filter(r => !r.header && !r.separator).every(r => r.checked !== undefined), "every choice is checkable");
    }

    function test_menuForARecording() {
        const rows = Model.menuModel("recordScreen", {saveTo: "clipboard", timer: "nope", microphone: "default", showPointer: true}, labels);
        compare(ids(rows), ["#Save to", "saveTo:desktop*", "saveTo:documents", "saveTo:preview", "-", "#Timer", "timer:none*",
            "timer:5", "timer:10", "-", "#Microphone", "microphone:none", "microphone:default*", "-", "#Options", "showPointer:toggle*"]);
        compare(rows[12].text, "Built-in Microphone", "the default input by its name");
    }

    function test_choice() {
        const o = {saveTo: "desktop", timer: "none", microphone: "none", showPointer: false};
        compare(Model.choice("saveTo:preview", o), {key: "saveTo", value: "preview"});
        compare(Model.choice("timer:10", o), {key: "timer", value: "10"});
        compare(Model.choice("microphone:default", o), {key: "microphone", value: "default"});
        compare(Model.choice("showPointer:toggle", o), {key: "showPointer", value: true});
        compare(Model.choice("showPointer:toggle", {showPointer: true}), {key: "showPointer", value: false});
        compare(Model.choice("saveTo:mail", o), null);
        compare(Model.choice("timer:3", o), null);
        compare(Model.choice("mode:screen", o), null, "the menu never changes the mode");
        compare(Model.choice("", o), null);
        compare(Model.choice("saveTo:desktop:x", o), null);
    }
}
