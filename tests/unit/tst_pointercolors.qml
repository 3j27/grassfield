import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Pointer colours (Settings > Accessibility > Pointer, ADR-0014): the two stored colours, the defaults of the packaged
// theme, the regeneration command, the build scheduling (debounced by the shell, one build at a time, the newest colours
// win), the colour maths of the colour well and the settings rules (schema parity lives in tst_settingsstore).
TestCase {
    name: "PointerColors"

    function test_defaults() {
        compare(PointerColors.DEFAULT_OUTLINE, "#ffffff");
        compare(PointerColors.DEFAULT_FILL, "#000000");
        compare(PointerColors.BASE_THEME, "grassfield-cursors");
        compare(PointerColors.CUSTOM_THEME, "grassfield-cursors-custom");
        // The defaults are what branding/cursors/build.sh uses without --fill/--outline.
        const build = PointerColors.buildCommand("/s/build.sh", "/icons", PointerColors.DEFAULT_OUTLINE, PointerColors.DEFAULT_FILL);
        compare(build.length, 10);
    }

    function test_validColor() {
        verify(PointerColors.validColor("#ff0000"));
        verify(PointerColors.validColor("#FfA0b1"));
        const bad = ["ff0000", "#ff00", "#ff00000", "#ff0000ff", "#gg0000", "", " #ff0000", "#ff0000\n", null, undefined, 16711680, ["#ff0000"], {}];
        for (const v of bad)
            verify(!PointerColors.validColor(v), "validColor(" + JSON.stringify(v) + ")");
    }

    function test_normalize() {
        compare(PointerColors.normalizeOutline("#FF0000"), "#ff0000");
        compare(PointerColors.normalizeFill("#00FF00"), "#00ff00");
        // A hand-edited value that is not #rrggbb is the default, never repaired.
        compare(PointerColors.normalizeOutline("red"), "#ffffff");
        compare(PointerColors.normalizeOutline(null), "#ffffff");
        compare(PointerColors.normalizeFill(undefined), "#000000");
        compare(PointerColors.normalizeFill("#12345"), "#000000");
        compare(PointerColors.normalizeFill(5), "#000000");
    }

    function test_keyAndTheme() {
        verify(PointerColors.isDefault("#ffffff", "#000000"));
        verify(PointerColors.isDefault("#FFFFFF", "#000000"));
        verify(PointerColors.isDefault(undefined, undefined));
        verify(!PointerColors.isDefault("#ffffff", "#ff0000"));
        verify(!PointerColors.isDefault("#ffff00", "#000000"));
        compare(PointerColors.key("#ffffff", "#000000"), "");
        compare(PointerColors.key("#FFFF00", "#FF0000"), "#ffff00|#ff0000");
        // Swapped colours are another pair, and not the default.
        compare(PointerColors.key("#000000", "#ffffff"), "#000000|#ffffff");
        compare(PointerColors.themeFor("#ffffff", "#000000", "grassfield-cursors"), "grassfield-cursors");
        compare(PointerColors.themeFor("#ffff00", "#ff0000", "grassfield-cursors"), "grassfield-cursors-custom");
        // Whatever the session theme, custom colours use the regenerated one.
        compare(PointerColors.themeFor("#ffff00", "#ff0000", ""), "grassfield-cursors-custom");
    }

    function test_iconsDir() {
        compare(PointerColors.iconsDir("/dev/icons", "/xdg", "/home/u", true), "/dev/icons");
        compare(PointerColors.iconsDir("", "/xdg", "/home/u", false), "/xdg/icons");
        compare(PointerColors.iconsDir("", "", "/home/u", false), "/home/u/.local/share/icons");
        compare(PointerColors.iconsDir(undefined, undefined, "/home/u", false), "/home/u/.local/share/icons");
        compare(PointerColors.iconsDir("", "", "", false), "");
        // A dev session without an isolated directory never falls back to the owner's data home.
        compare(PointerColors.iconsDir("", "/xdg", "/home/u", true), "");
        compare(PointerColors.iconsDir("", "", "/home/u", true), "");
    }

    function test_buildCommand() {
        const c = PointerColors.buildCommand("/usr/share/grassfield/cursors/build.sh", "/home/u/.local/share/icons", "#FFFF00", "#FF0000");
        compare(c, ["bash", "/usr/share/grassfield/cursors/build.sh", "--out", "/home/u/.local/share/icons", "--name", "grassfield-cursors-custom", "--outline", "#ffff00", "--fill", "#ff0000"]);
        // Paths with spaces stay one element each (no shell).
        const sp = PointerColors.buildCommand("/a b/build.sh", "/c d/icons", "#ffff00", "#ff0000");
        compare(sp[1], "/a b/build.sh");
        compare(sp[3], "/c d/icons");
        // Nothing is built from a colour that is not #rrggbb (no injection through a stored value), a missing script or directory.
        compare(PointerColors.buildCommand("/s", "/d", "#ff0000; rm -rf /", "#000000"), []);
        compare(PointerColors.buildCommand("/s", "/d", "#ff0000", "$(id)"), []);
        compare(PointerColors.buildCommand("/s", "/d", "red", "#000000"), []);
        compare(PointerColors.buildCommand("", "/d", "#ff0000", "#000000"), []);
        compare(PointerColors.buildCommand("/s", "", "#ff0000", "#000000"), []);
        compare(PointerColors.buildCommand(null, "/d", "#ff0000", "#000000"), []);
        // The theme name is fixed: always the custom one.
        verify(PointerColors.buildCommand("/s", "/d", "#ff0000", "#000000").indexOf("grassfield-cursors-custom") > 0);
    }

    function test_removeCommand() {
        compare(PointerColors.removeCommand("/s/build.sh", "/icons"), ["bash", "/s/build.sh", "--remove", "--out", "/icons", "--name", "grassfield-cursors-custom"]);
        compare(PointerColors.removeCommand("", "/icons"), []);
        compare(PointerColors.removeCommand("/s/build.sh", ""), []);
    }

    function test_failureReason() {
        compare(PointerColors.failureReason(1, "cursors: rsvg-convert not found\n"), "cursors: rsvg-convert not found");
        compare(PointerColors.failureReason(1, "noise\n\ncursors: hyprcursor-util not found\n\n"), "cursors: hyprcursor-util not found");
        compare(PointerColors.failureReason(127, "bash: /x: No such file or directory"), "the cursor builder is not installed");
        compare(PointerColors.failureReason(1, ""), "the cursor builder failed (exit 1)");
        compare(PointerColors.failureReason(2, undefined), "the cursor builder failed (exit 2)");
        // One short line of plain text: control characters are removed, the length is bounded.
        compare(PointerColors.failureReason(1, "a\u001b[31mb\u0007c"), "a [31mb c");
        compare(PointerColors.failureReason(1, "x".repeat(500)).length, 160);
    }

    // ---- build scheduling ----

    function test_scheduleStartsOnce() {
        let s = PointerColors.initialState();
        compare(PointerColors.decide(s), "none");
        s = PointerColors.want(s, "#a|#b");
        compare(PointerColors.decide(s), "start");
        s = PointerColors.started(s);
        // A running build for the wanted pair is left alone (no second process).
        compare(PointerColors.decide(s), "none");
        s = PointerColors.exited(s, true);
        compare(s.built, "#a|#b");
        compare(PointerColors.decide(s), "none");
        // The same pair again builds nothing.
        s = PointerColors.want(s, "#a|#b");
        compare(PointerColors.decide(s), "none");
    }

    function test_scheduleSupersedes() {
        let s = PointerColors.want(PointerColors.initialState(), "#1|#1");
        s = PointerColors.started(s);
        // New colours while one build runs: terminate it, once, never start a second one next to it.
        s = PointerColors.want(s, "#2|#2");
        compare(PointerColors.decide(s), "terminate");
        s = PointerColors.terminating(s);
        compare(PointerColors.decide(s), "none");
        // More changes while it stops: still one termination, and the last pair wins.
        s = PointerColors.want(s, "#3|#3");
        compare(PointerColors.decide(s), "none");
        s = PointerColors.exited(s, false);
        // A terminated build is neither built nor failed.
        compare(s.built, "");
        compare(s.failed, "");
        compare(s.running, "");
        compare(PointerColors.decide(s), "start");
        s = PointerColors.started(s);
        compare(s.running, "#3|#3");
        s = PointerColors.exited(s, true);
        compare(s.built, "#3|#3");
    }

    function test_scheduleFailure() {
        let s = PointerColors.want(PointerColors.initialState(), "#1|#1");
        s = PointerColors.started(s);
        s = PointerColors.exited(s, false);
        compare(s.failed, "#1|#1");
        // A failed pair is not retried in a loop...
        compare(PointerColors.decide(s), "none");
        s = PointerColors.want(s, "#1|#1");
        compare(PointerColors.decide(s), "none");
        // ...until the colours change.
        s = PointerColors.want(s, "#2|#2");
        compare(s.failed, "");
        compare(PointerColors.decide(s), "start");
    }

    function test_scheduleResetCancels() {
        let s = PointerColors.want(PointerColors.initialState(), "#1|#1");
        s = PointerColors.started(s);
        // Back to the default pair: the running build is useless.
        s = PointerColors.want(s, "");
        compare(PointerColors.decide(s), "terminate");
        s = PointerColors.terminating(s);
        s = PointerColors.exited(s, false);
        compare(PointerColors.decide(s), "none");
        compare(s.built, "");
    }

    function test_scheduleBuiltKeptAcrossChanges() {
        let s = PointerColors.want(PointerColors.initialState(), "#1|#1");
        s = PointerColors.exited(PointerColors.started(s), true);
        // Another pair, then back to the first: still built on disk only if the second never finished.
        s = PointerColors.want(s, "#2|#2");
        s = PointerColors.started(s);
        s = PointerColors.want(s, "#1|#1");
        compare(PointerColors.decide(s), "terminate");
        s = PointerColors.exited(PointerColors.terminating(s), false);
        compare(s.built, "#1|#1");
        compare(PointerColors.decide(s), "none");
    }

    // ---- colour well maths ----

    function test_hsv() {
        compare(PointerColors.fromHsv(0, 1, 1), "#ff0000");
        compare(PointerColors.fromHsv(1 / 3, 1, 1), "#00ff00");
        compare(PointerColors.fromHsv(2 / 3, 1, 1), "#0000ff");
        compare(PointerColors.fromHsv(0, 0, 1), "#ffffff");
        compare(PointerColors.fromHsv(0.5, 0.5, 0), "#000000");
        compare(PointerColors.fromHsv(0.7, 2, -1), "#000000");
        // Round trip over a grid of colours (to the nearest value of the 8 bit channels).
        for (const c of ["#e5484d", "#3e7bfa", "#808080", "#010203", "#fefefe", "#ffff00"]) {
            const hsv = PointerColors.toHsv(c);
            compare(PointerColors.fromHsv(hsv.h, hsv.s, hsv.v), c);
        }
        compare(PointerColors.toHsv("nope"), null);
        compare(PointerColors.toHsv("#000000").v, 0);
        compare(PointerColors.toHsv("#ffffff").s, 0);
    }

    function test_parseTyped() {
        compare(PointerColors.parseTyped("#FF00aa"), "#ff00aa");
        compare(PointerColors.parseTyped("ff00aa"), "#ff00aa");
        compare(PointerColors.parseTyped("  #f0a "), "#ff00aa");
        compare(PointerColors.parseTyped("#ff00a"), "");
        compare(PointerColors.parseTyped("#gg00aa"), "");
        compare(PointerColors.parseTyped(""), "");
        compare(PointerColors.parseTyped(null), "");
    }

    // ---- settings rules ----

    function test_settingsRules() {
        compare(Store.DEFAULTS["pointer.outlineColor"], "#ffffff");
        compare(Store.DEFAULTS["pointer.fillColor"], "#000000");
        compare(Store.validate("pointer.outlineColor", "#ff0000"), "");
        compare(Store.validate("pointer.fillColor", "#00FF00"), "");
        for (const v of ["red", "#ff00", "#ff0000ff", 5, null, true, ""])
            verify(Store.validate("pointer.fillColor", v) !== "", "fillColor " + JSON.stringify(v));
        const r = Store.setValue('{"version":1,"pointer":{"size":48}}', "pointer.outlineColor", "#ffff00");
        verify(r.ok);
        compare(JSON.parse(r.text), {version: 1, pointer: {size: 48, outlineColor: "#ffff00"}});
        verify(!Store.setValue("{}", "pointer.fillColor", "javascript:alert(1)").ok);
        // A hand-edited stored value that is not a colour reads as the default.
        compare(Store.read({pointer: {fillColor: "red"}}, "pointer.fillColor"), "#000000");
        compare(Store.read({pointer: {outlineColor: "#112233"}}, "pointer.outlineColor"), "#112233");
        compare(Store.read({}, "pointer.outlineColor"), "#ffffff");
    }

    function test_launchEnvironmentTheme() {
        compare(PointerSize.launchEnvironment(24, 24, "", "grassfield-cursors"), {});
        compare(PointerSize.launchEnvironment(24, 24, "grassfield-cursors", "grassfield-cursors"), {});
        compare(PointerSize.launchEnvironment(24, 24, "grassfield-cursors-custom", "grassfield-cursors"), {"XCURSOR_THEME": "grassfield-cursors-custom", "HYPRCURSOR_THEME": "grassfield-cursors-custom"});
        compare(PointerSize.launchEnvironment(48, 24, "grassfield-cursors-custom", "grassfield-cursors"), {"XCURSOR_SIZE": "48", "HYPRCURSOR_SIZE": "48", "XCURSOR_THEME": "grassfield-cursors-custom", "HYPRCURSOR_THEME": "grassfield-cursors-custom"});
        // Only a plain theme name reaches an environment.
        compare(PointerSize.launchEnvironment(24, 24, "a b", "grassfield-cursors"), {});
        compare(PointerSize.launchEnvironment(24, 24, "../x", "grassfield-cursors"), {});
        compare(PointerSize.launchEnvironment(24, 24, null, "grassfield-cursors"), {});
    }
}
