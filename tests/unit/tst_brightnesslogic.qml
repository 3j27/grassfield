import QtQuick
import QtTest
import "../../shell/services/BrightnessLogic.js" as Logic

// Per-output brightness (ADR-0045 OC-4, shell/services/BrightnessLogic.js): the answer of Omarchy's
// omarchy-brightness-display-ddc, the 5-point key step, which output a key and Quick Settings' slider act on, and the
// one-command-per-output queue (the last value wins, steps add up, a replug waits for the command still running).
TestCase {
    name: "BrightnessLogic"

    function test_names() {
        for (const n of ["eDP-1", "LVDS-1", "DSI-1", "eDP-2"])
            verify(Logic.isBuiltIn(n), n);
        for (const n of ["DP-1", "HDMI-A-1", "edp-1", "eDP", "", "WAYLAND-1"])
            verify(!Logic.isBuiltIn(n), n);
        verify(!Logic.isBuiltIn(undefined));
        for (const n of ["DP-1", "HDMI-A-1", "eDP-1", "DVI-D-2", "DP-10", "Unknown-1", "HEADLESS-2"])
            verify(Logic.isConnector(n), n);
        for (const n of ["", "-x", "--help", "DP-", "DP1", "1-DP", "DP-1 ", "DP-1\n", "../DP-1", "DP/1", "DP-1;rm", "D P-1", "DP-12345",
                         "A".repeat(25) + "-1"])
            verify(!Logic.isConnector(n), JSON.stringify(n));
        verify(!Logic.isConnector(null));
        compare(Logic.builtIn(["DP-1", "eDP-1", "HDMI-A-1"]), "eDP-1");
        compare(Logic.builtIn(["DP-1", "HDMI-A-1"]), "");
        compare(Logic.builtIn(undefined), "");
    }

    // The command prints the level alone on its line, or nothing (exit 1) without DDC/CI.
    function test_parsePercent() {
        compare(Logic.parsePercent("40\n"), 40);
        compare(Logic.parsePercent("0"), 0);
        compare(Logic.parsePercent(" 100 \n"), 100);
        compare(Logic.parsePercent("7"), 7);
        for (const t of ["", "\n", "101", "-5", "40%", "4.5", "40\n41\n", "abc", "1000", "Display not found"])
            compare(Logic.parsePercent(t), -1, JSON.stringify(t));
        compare(Logic.parsePercent(undefined), -1);
        compare(Logic.parsePercent(40), -1);
    }

    // 5 points a press, as the backlight keys (brightnessctl 5%+ / 5%-), within the command's 1..100.
    function test_stepPercent() {
        compare(Logic.stepPercent(40, "up"), 45);
        compare(Logic.stepPercent(40, "down"), 35);
        compare(Logic.stepPercent(98, "up"), 100);
        compare(Logic.stepPercent(100, "up"), 100);
        compare(Logic.stepPercent(3, "down"), 1);
        compare(Logic.stepPercent(0, "down"), 1);
        compare(Logic.stepPercent(0, "up"), 5);
        compare(Logic.stepPercent(40, "mute"), 40);
        compare(Logic.stepPercent(NaN, "up"), 5);
    }

    function test_argv() {
        compare(Logic.argvFor("DP-1", {kind: "query"}), ["omarchy-brightness-display-ddc", "DP-1"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 40}), ["omarchy-brightness-display-ddc", "DP-1", "40%"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 0}), ["omarchy-brightness-display-ddc", "DP-1", "1%"]);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: 140}), ["omarchy-brightness-display-ddc", "DP-1", "100%"]);
        compare(Logic.argvFor("HDMI-A-1", {kind: "step", steps: 1}), ["omarchy-brightness-display-ddc", "HDMI-A-1", "+5%"]);
        compare(Logic.argvFor("HDMI-A-1", {kind: "step", steps: -3}), ["omarchy-brightness-display-ddc", "HDMI-A-1", "15%-"]);
        compare(Logic.argvFor("DP-1", {kind: "step", steps: 40}), ["omarchy-brightness-display-ddc", "DP-1", "+100%"]);
        compare(Logic.argvFor("DP-1", {kind: "step", steps: 0}), null);
        compare(Logic.argvFor("DP-1", {kind: "set", percent: NaN}), null);
        compare(Logic.argvFor("-x", {kind: "query"}), null);
        compare(Logic.argvFor("DP-1", null), null);
        compare(Logic.argvFor("DP-1", {kind: "rm"}), null);
    }

    function okEntry(level) {
        return Object.assign(Logic.fresh(), {status: "ok", level: level, serial: 1});
    }

    // The first query: probing, then ok with its level, or none (one journal line: `failed`).
    function test_probe() {
        let r = Logic.request(Logic.fresh(), "DP-1", {kind: "query"});
        compare(r.start, ["omarchy-brightness-display-ddc", "DP-1"]);
        compare(r.entry.status, "probing");
        verify(r.entry.busy);
        let f = Logic.finished(r.entry, "DP-1", "40\n");
        compare(f.entry.status, "ok");
        compare(f.entry.level, 40);
        verify(!f.entry.busy);
        compare(f.start, null);
        verify(!f.failed);
        f = Logic.finished(r.entry, "DP-1", "");
        compare(f.entry.status, "none");
        verify(f.failed);
        verify(!Logic.answers({"DP-1": f.entry}, "DP-1"));
        // A display that does not answer takes no change.
        const no = Logic.request(f.entry, "DP-1", {kind: "step", steps: 1});
        compare(no.start, null);
        verify(!no.entry.busy);
        compare(no.entry.pending, null);
    }

    // At most one command per output: what comes meanwhile waits; a set replaces what waited (the last value wins).
    function test_coalescingSets() {
        let r = Logic.request(okEntry(40), "DP-1", {kind: "set", percent: 50});
        compare(r.start, ["omarchy-brightness-display-ddc", "DP-1", "50%"]);
        compare(r.entry.level, 50);
        for (const p of [55, 60, 70]) {
            r = Logic.request(r.entry, "DP-1", {kind: "set", percent: p});
            compare(r.start, null, "nothing starts while one runs");
            compare(r.entry.level, p, "the slider shows the value at once");
        }
        compare(r.entry.pending, {kind: "set", percent: 70});
        const f = Logic.finished(r.entry, "DP-1", "50\n");
        compare(f.start, ["omarchy-brightness-display-ddc", "DP-1", "70%"], "only the last value is sent");
        verify(f.entry.busy);
        compare(f.entry.pending, null);
        compare(f.entry.level, 70);
        const g = Logic.finished(f.entry, "DP-1", "70\n");
        compare(g.start, null);
        verify(!g.entry.busy);
        compare(g.entry.level, 70);
    }

    // Key presses add up while a command runs; the printed level corrects the expected one.
    function test_coalescingSteps() {
        let r = Logic.request(okEntry(40), "DP-1", {kind: "step", steps: 1});
        compare(r.start, ["omarchy-brightness-display-ddc", "DP-1", "+5%"]);
        compare(r.entry.level, 45);
        r = Logic.request(r.entry, "DP-1", {kind: "step", steps: 1});
        r = Logic.request(r.entry, "DP-1", {kind: "step", steps: 1});
        compare(r.start, null);
        compare(r.entry.level, 55);
        compare(r.entry.pending, {kind: "step", steps: 2});
        // The display was at 30, not 40 (Settings changed it): the command stepped from its own level.
        const f = Logic.finished(r.entry, "DP-1", "35\n");
        compare(f.start, ["omarchy-brightness-display-ddc", "DP-1", "+10%"]);
        compare(f.entry.level, 45);
        // Up then down while one runs: nothing more to send.
        let u = Logic.request(okEntry(40), "DP-1", {kind: "step", steps: 1});
        u = Logic.request(u.entry, "DP-1", {kind: "step", steps: 1});
        u = Logic.request(u.entry, "DP-1", {kind: "step", steps: -1});
        compare(u.entry.pending, {kind: "step", steps: 0});
        const h = Logic.finished(u.entry, "DP-1", "45\n");
        compare(h.start, null);
        verify(!h.entry.busy);
        compare(h.entry.level, 45);
    }

    // A step after a waiting set moves the set; a set after waiting steps replaces them; a query waits behind a change.
    function test_merge() {
        compare(Logic.merge({kind: "set", percent: 60}, {kind: "step", steps: -1}), {kind: "set", percent: 55});
        compare(Logic.merge({kind: "step", steps: 3}, {kind: "set", percent: 20}), {kind: "set", percent: 20});
        compare(Logic.merge(null, {kind: "query"}), {kind: "query"});
        compare(Logic.merge({kind: "step", steps: 1}, {kind: "query"}), {kind: "step", steps: 1});
        compare(Logic.merge({kind: "query"}, {kind: "step", steps: -2}), {kind: "step", steps: -2});
        compare(Logic.merge({kind: "set", percent: 99}, {kind: "step", steps: 1}), {kind: "set", percent: 100});
    }

    // A write that fails on a display that answered keeps it, up to three in a row; then it is a display without DDC/CI.
    function test_failures() {
        let e = okEntry(40);
        for (let i = 1; i <= 2; i++) {
            const r = Logic.request(e, "DP-1", {kind: "set", percent: 50});
            const f = Logic.finished(r.entry, "DP-1", "");
            compare(f.entry.status, "ok");
            compare(f.entry.failures, i);
            verify(!f.failed);
            e = f.entry;
        }
        const ok = Logic.finished(Logic.request(e, "DP-1", {kind: "set", percent: 50}).entry, "DP-1", "50");
        compare(ok.entry.failures, 0, "an answer resets the count");
        e = okEntry(40);
        let last = null;
        for (let i = 0; i < 3; i++) {
            const r = Logic.request(e, "DP-1", {kind: "step", steps: 1});
            r.entry.pending = {kind: "step", steps: 1};
            last = Logic.finished(r.entry, "DP-1", "");
            e = last.entry;
            if (i < 2)
                compare(last.start, ["omarchy-brightness-display-ddc", "DP-1", "+5%"], "what waited still runs");
        }
        compare(e.status, "none");
        verify(last.failed);
        compare(last.start, null, "nothing more runs on a display that stopped answering");
    }

    // The keys act on the active display when it can be changed; else on the built-in panel's backlight (macOS).
    function test_keyTarget() {
        const ddc = {"DP-1": okEntry(40), "HDMI-A-1": Object.assign(Logic.fresh(), {status: "none"}), "DP-2": Object.assign(Logic.fresh(), {status: "probing"})};
        const names = ["eDP-1", "DP-1", "HDMI-A-1", "DP-2"];
        compare(Logic.keyTarget("DP-1", names, true, ddc), {kind: "ddc", output: "DP-1"});
        compare(Logic.keyTarget("eDP-1", names, true, ddc), {kind: "backlight", output: "eDP-1"});
        compare(Logic.keyTarget("HDMI-A-1", names, true, ddc), {kind: "backlight", output: "eDP-1"}, "no DDC/CI: the built-in panel");
        compare(Logic.keyTarget("DP-2", names, true, ddc), {kind: "backlight", output: "eDP-1"}, "not answered yet");
        compare(Logic.keyTarget("HDMI-A-1", ["DP-1", "HDMI-A-1"], false, ddc), {kind: "none", output: "HDMI-A-1"});
        compare(Logic.keyTarget("DP-1", ["DP-1", "HDMI-A-1"], false, ddc), {kind: "ddc", output: "DP-1"}, "a desktop");
        compare(Logic.keyTarget("DP-3", ["DP-3"], true, {}), {kind: "backlight", output: ""}, "an all-in-one's panel: the active display");
        compare(Logic.keyTarget("", [], false, {}), {kind: "none", output: ""});
        compare(Logic.keyTarget("", ["eDP-1"], true, null), {kind: "backlight", output: "eDP-1"});
        // A built-in name never goes over DDC/CI, whatever an entry says.
        compare(Logic.keyTarget("eDP-1", names, false, {"eDP-1": okEntry(10)}), {kind: "none", output: "eDP-1"});
    }

    // Quick Settings' Display: the built-in display's, else the main display's when it answers.
    function test_sliderTarget() {
        const ddc = {"DP-1": okEntry(40), "DP-2": Object.assign(Logic.fresh(), {status: "none"})};
        compare(Logic.sliderTarget(["eDP-1", "DP-1"], true, ddc, "DP-1"), {kind: "backlight", output: "eDP-1"});
        compare(Logic.sliderTarget(["DP-1", "DP-2"], false, ddc, "DP-1"), {kind: "ddc", output: "DP-1"});
        compare(Logic.sliderTarget(["DP-1", "DP-2"], false, ddc, "DP-2"), {kind: "none", output: ""});
        compare(Logic.sliderTarget(["DP-1"], false, ddc, ""), {kind: "none", output: ""});
        compare(Logic.sliderTarget([], false, {}, undefined), {kind: "none", output: ""});
    }

    // New external outputs are asked once; built-in and odd names never; an output that went away is forgotten (a replug asks
    // again); a new display on a connector whose command still runs waits for it, and that command's answer is not its own.
    function test_sync() {
        let s = Logic.sync({}, ["eDP-1", "DP-1", "HDMI-A-1", "WAYLAND-1", "HEADLESS-2", "-x", "DP-1"], {}, 0);
        compare(s.ask, ["DP-1", "HDMI-A-1"]);
        compare(Object.keys(s.ddc).sort(), ["DP-1", "HDMI-A-1"]);
        compare(s.ddc["DP-1"].serial, 1);
        compare(s.ddc["HDMI-A-1"].serial, 2);
        compare(s.serial, 2);
        verify(Logic.isVirtual("WAYLAND-1") && Logic.isVirtual("HEADLESS-2") && !Logic.isVirtual("DP-1"));
        const kept = Object.assign({}, s.ddc);
        kept["DP-1"] = okEntry(40);
        s = Logic.sync(kept, ["eDP-1", "DP-1"], {}, s.serial);
        compare(s.ask, []);
        compare(s.ddc["DP-1"].level, 40, "a known display keeps its state");
        compare(Object.keys(s.ddc), ["DP-1"]);
        s = Logic.sync({}, ["DP-1"], {"DP-1": true}, 7);
        compare(s.ask, [], "a command of the display before still runs");
        verify(s.ddc["DP-1"].busy);
        compare(s.ddc["DP-1"].pending, {kind: "query"});
        compare(s.ddc["DP-1"].serial, 8);
        const r = Logic.released(s.ddc["DP-1"], "DP-1");
        compare(r.start, ["omarchy-brightness-display-ddc", "DP-1"], "its own query runs once the old command ends");
        compare(r.entry.status, "probing");
        verify(r.entry.busy);
        const idle = Logic.released(Object.assign(Logic.fresh(), {busy: true}), "DP-1");
        compare(idle.start, null);
        verify(!idle.entry.busy);
    }
}
