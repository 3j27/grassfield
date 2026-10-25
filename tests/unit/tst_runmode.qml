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

    // Mode.qml reads the right variables, by name: the runtime test (tests/shell/run_mode_import) runs with most of them unset, so
    // a misspelled GRASSFIELD_SESION would pass there. Each property's Quickshell.env names, in order, against the table.
    function test_modeReadsTheRightVariables() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/lib/Mode.qml"), false);
        request.send();
        const source = request.responseText.replace(/\/\/[^\n]*/g, "");
        const table = vectors().modeReads;
        const allowed = {};
        let seen = 0;
        for (const prop of Object.keys(table)) {
            if (prop === "comment")
                continue;
            const m = new RegExp("readonly property \\w+ " + prop + ": RunMode\\.(\\w+)\\(([^\\n]*)\\)\\n").exec(source);
            verify(m !== null, "Mode." + prop + " is a RunMode call");
            const names = [];
            const re = /Quickshell\.env\("([A-Za-z0-9_]+)"\)/g;
            let e;
            while ((e = re.exec(m[2])) !== null)
                names.push(e[1]);
            compare(names.join(","), table[prop].join(","), "Mode." + prop + " reads");
            table[prop].forEach(n => allowed[n] = true);
            seen++;
        }
        verify(seen >= 7, "properties checked: " + seen);
        // No other read: every Quickshell.env("...") literal of the file is in the table, and the one dynamic read is devValue's.
        const re2 = /Quickshell\.env\("([A-Za-z0-9_]+)"\)/g;
        let e2;
        while ((e2 = re2.exec(source)) !== null)
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
