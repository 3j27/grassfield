import QtQuick
import QtTest
import "../../shell/lib/RunMode.js" as RunMode

// ADR-0019 (GF-089): the one run-mode rule, held to tests/fixtures/run-mode-vectors.json (the C++ side, apps/runmode.h,
// is held to the same file from slice M6). The runtime check of the singleton (Quickshell.env) is
// tests/shell/run_mode_import/shell.qml.
TestCase {
    name: "RunMode"

    function vectors() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../fixtures/run-mode-vectors.json"), false);
        request.send();
        return JSON.parse(request.responseText);
    }

    function test_modeVectors() {
        const modes = vectors().modes;
        verify(modes.length >= 15, "vectors read: " + modes.length);
        for (const v of modes) {
            const e = v.env;
            compare(RunMode.dev(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION), v.dev, v.name + " (dev)");
            compare(RunMode.session(e.GRASSFIELD_SESSION), v.session, v.name + " (session)");
            compare(RunMode.fixtures(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e.GRASSFIELD_VISUAL_FIXTURES), v.fixtures, v.name + " (fixtures)");
            compare(RunMode.ownBus(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e.GRASSFIELD_PRIVATE_BUS), v.ownBus, v.name + " (ownBus)");
            compare(RunMode.updateNotices(e.GRASSFIELD_SESSION), v.updateNotices, v.name + " (updateNotices)");
        }
    }

    function test_dirVectors() {
        const dirs = vectors().dirs;
        verify(dirs.length >= 5, "vectors read: " + dirs.length);
        for (const v of dirs) {
            const e = v.env;
            compare(RunMode.configDir(e.GRASSFIELD_CONFIG_HOME, e.XDG_CONFIG_HOME, e.HOME), v.configDir, v.name + " (configDir)");
            compare(RunMode.stateDir(e.GRASSFIELD_STATE_HOME, e.XDG_STATE_HOME, e.HOME), v.stateDir, v.name + " (stateDir)");
        }
    }

    function test_plumbingVectors() {
        const rows = vectors().plumbing;
        verify(rows.length >= 4, "vectors read: " + rows.length);
        for (const v of rows) {
            const e = v.env;
            compare(RunMode.devPlumbing(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e[v.variable]), v.value, v.name);
        }
    }

    // Mode.qml calls the right rule on the right variables, by name: the runtime test (tests/shell/run_mode_import) runs with most of
    // them unset, so a misspelled GRASSFIELD_SESION or `fixtures: RunMode.ownBus(...)` would pass there. Each member's RunMode function
    // and Quickshell.env names, in order, against the table; devValue (the gate of every dev-plumbing variable) is checked the same way.
    function test_modeCallsTheRightRuleOnTheRightVariables() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/lib/Mode.qml"), false);
        request.send();
        const source = request.responseText.replace(/\/\/[^\n]*/g, "");
        const table = vectors().modeReads;
        const literal = /Quickshell\.env\("([A-Za-z0-9_]+)"\)/g;
        const allowed = {};
        let seen = 0;
        for (const member of Object.keys(table)) {
            if (member === "comment")
                continue;
            const row = table[member];
            const pattern = row["function"] === true
                ? "function " + member + "\\(name\\) \\{\\s*return RunMode\\.(\\w+)\\(([^\\n]*)\\);"
                : "readonly property \\w+ " + member + ": RunMode\\.(\\w+)\\(([^\\n]*)\\)\\n";
            const m = new RegExp(pattern).exec(source);
            verify(m !== null, "Mode." + member + " is a RunMode call");
            compare(m[1], row.call, "Mode." + member + " calls RunMode." + row.call);
            // The whole argument text of the call, whitespace normalised: `env("A"), env("B") && ""` is not env("B").
            const args = m[2].split(",").map(a => a.replace(/\s+/g, " ").trim());
            const expected = row.reads.map(n => 'Quickshell.env("' + n + '")');
            if (row["function"] === true)
                expected.push('Quickshell.env("GRASSFIELD_" + name)');
            compare(args.join(" | "), expected.join(" | "), "Mode." + member + " arguments");
            row.reads.forEach(n => allowed[n] = true);
            seen++;
        }
        verify(seen >= 8, "members checked: " + seen);
        // The other direction: every member of Mode.qml is in the table (shellDir reads no variable and is pinned here).
        const plain = {"shellDir": "Quickshell.shellDir"};
        const memberRe = /(?:readonly property \w+ (\w+):|function (\w+)\()/g;
        let mm;
        while ((mm = memberRe.exec(source)) !== null) {
            const name = mm[1] || mm[2];
            verify(table[name] !== undefined || plain[name] !== undefined, "Mode." + name + " is not in the modeReads table");
        }
        verify(source.indexOf("readonly property string shellDir: Quickshell.shellDir\n") >= 0, "Mode.shellDir is Quickshell.shellDir");
        // No other read: every Quickshell.env("...") literal of the file is in the table, and the one dynamic read is devValue's.
        let e2;
        literal.lastIndex = 0;
        while ((e2 = literal.exec(source)) !== null)
            verify(allowed[e2[1]] === true, "unexpected read of " + e2[1]);
        const dynamic = (source.match(/Quickshell\.env\([^)]*\)/g) || []).filter(c => !/^Quickshell\.env\("[A-Za-z0-9_]+"\)$/.test(c));
        compare(dynamic.length, 1, "one dynamic read");
        verify(dynamic[0].indexOf('"GRASSFIELD_" + name') >= 0, "the dynamic read is GRASSFIELD_<name>: " + dynamic[0]);
    }

    // Only exact strings open a gate, whatever else the caller passes.
    function test_closedWithoutExactDev() {
        const values = [undefined, null, "", "0", "true", "yes", " 1", "1 ", "01", 1, true];
        for (let i = 0; i < values.length; i++) {
            verify(!RunMode.dev(values[i], undefined), JSON.stringify(values[i]));
            verify(!RunMode.fixtures(values[i], undefined, "1"), JSON.stringify(values[i]) + " (fixtures)");
        }
    }

    function test_privateBusNeedsTheExactString() {
        const values = [undefined, null, "", "0", "true", 1, true];
        for (let i = 0; i < values.length; i++)
            verify(!RunMode.ownBus("1", undefined, values[i]), JSON.stringify(values[i]));
    }
}
