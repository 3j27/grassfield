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

    // The source of Mode.qml without comments, by the simple rule (`//` to the end of the line, `/* */`), which is exact only if no
    // string, regex or template literal holds a comment marker: a marker after an odd number of quotes on its line fails, and so
    // does a backtick, a single quote or any `/` that is left (a regex literal or a division). Mode.qml needs none of them.
    function modeSource() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/lib/Mode.qml"), false);
        request.send();
        const src = request.responseText;
        let out = "";
        let i = 0;
        while (i < src.length) {
            if (src.startsWith("//", i) || src.startsWith("/*", i)) {
                const lineStart = src.lastIndexOf("\n", i - 1) + 1;
                compare((src.slice(lineStart, i).match(/"/g) || []).length % 2, 0, "a comment marker inside a string at offset " + i);
                if (src.startsWith("//", i)) {
                    const eol = src.indexOf("\n", i);
                    i = eol < 0 ? src.length : eol;
                } else {
                    const end = src.indexOf("*/", i + 2);
                    verify(end >= 0, "an unterminated block comment at offset " + i);
                    out += " ";
                    i = end + 2;
                }
                continue;
            }
            out += src[i++];
        }
        verify(out.indexOf("`") < 0, "Mode.qml holds no template literal");
        verify(out.indexOf("'") < 0, "Mode.qml holds no single-quoted string");
        verify(out.indexOf("/") < 0, "Mode.qml holds no regex literal or division outside comments");
        return out;
    }

    // Mode.qml calls the right rule on the right variables, by name: the runtime test (tests/shell/run_mode_import) runs with most of
    // them unset, so a misspelled GRASSFIELD_SESION or `fixtures: RunMode.ownBus(...)` would pass there. Each member's RunMode function
    // and Quickshell.env arguments, in order and whole, against the table; devValue (the gate of every dev-plumbing variable) is
    // checked the same way, and every member declaration of every form must be in the table.
    function test_modeCallsTheRightRuleOnTheRightVariables() {
        const source = modeSource();
        const table = vectors().modeReads;
        const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
        const literal = /Quickshell\.env\("([A-Za-z0-9_]+)"\)/g;
        const allowed = {};
        let seen = 0;
        for (const member of Object.keys(table)) {
            if (member === "comment")
                continue;
            const row = table[member];
            const pattern = row["function"] === true
                ? "function\\s+" + member + "\\s*\\(\\s*name\\s*\\)\\s*\\{\\s*return\\s+RunMode\\.(\\w+)\\(([^\\n]*)\\);"
                : "readonly\\s+property\\s+\\w+\\s+" + member + "\\s*:\\s*RunMode\\.(\\w+)\\(([^\\n]*)\\)\\s*\\n";
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
        // The other direction: every member declaration of Mode.qml (property of any form, function, signal) is in the table.
        // shellDir and refused read no variable and are pinned to their exact expression.
        const plain = {"shellDir": "Quickshell.shellDir", "refused": "RunMode.REFUSED"};
        const declared = {};
        const memberRe = /\bproperty\s+[\w.<>]+\s+(\w+)|\b(?:function|signal)\s+(\w+)/g;
        let mm;
        while ((mm = memberRe.exec(source)) !== null) {
            const name = mm[1] || mm[2];
            declared[name] = (declared[name] || 0) + 1;
            verify((own(table, name) && name !== "comment") || own(plain, name), "Mode." + name + " is not in the modeReads table");
        }
        for (const name of Object.keys(declared))
            compare(declared[name], 1, "Mode." + name + " is declared once");
        for (const name of Object.keys(plain)) {
            const re = new RegExp("readonly\\s+property\\s+string\\s+" + name + "\\s*:\\s*" + plain[name].replace(/\./g, "\\.") + "\\s*\\n");
            verify(re.test(source), "Mode." + name + " is " + plain[name]);
        }
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
