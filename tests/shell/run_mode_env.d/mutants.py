#!/usr/bin/env python3
"""Mutation suite of tests/shell/run_mode_env.sh (ADR-0019): every way of opening a gate it is meant to catch, as a labelled patch.

Each mutant is a scratch copy of shell/lib (Mode.qml, RunMode.js, qmldir, or extra files) built under a temp directory with a few
exact text replacements; the real tree is never touched. The suite runs the check against the copy with GF_RUN_MODE_LIB and asserts
that it FAILS. Also asserted: the unmodified copy passes (both layers), and copies that change comments and layout only pass.

  tests/shell/run_mode_env_mutants.sh            all mutants (structure layer for each; the behaviour layer alone for the ones marked B)
  tests/shell/run_mode_env_mutants.sh <text>     only mutants whose label contains <text>

A mutant marked B must also fail the behaviour layer alone (GF_RUN_MODE_ONLY=behaviour): it changes what the real Mode answers,
whatever the source looks like. The others are caught by the structure layer alone (GF_RUN_MODE_ONLY=structure): they depend on a
variable no vector sets, or only change the shape. Adding a mutant: add a row to MUTANTS.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "shell" / "lib"
RUN = ROOT / "tests" / "shell" / "run_mode_env.d" / "run.py"
BASE = {f: (LIB / f).read_text(encoding="utf-8") for f in ("Mode.qml", "RunMode.js", "qmldir")}

# Anchors in the real files; the suite fails loudly if one is gone (then update the anchors, not the checks).
DEV = 'readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))'
SHELLDIR = "readonly property string shellDir: Quickshell.shellDir"
DEVVALUE_RETURN = 'return RunMode.devPlumbing(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_" + name));'
RM_DEV = 'return devValue === "1" && sessionValue !== "1";'
RM_FIXTURES = 'return dev(devValue, sessionValue) && fixturesValue === "1";'
RM_SESSION = 'return sessionValue === "1";'
RM_REFUSED = 'var REFUSED = "refused";'
RM_PLUMBING_CHECK = 'if (!dev(devValue, sessionValue))\n        return "";\n'


def late(ms):
    return [(DEV, 'property bool lateOpen: false\n    Timer { interval: %d; running: true; onTriggered: root.lateOpen = true }\n    %s || lateOpen' % (ms, DEV))]


def mode(*patches):
    return {"Mode.qml": list(patches)}


def rm(*patches):
    return {"RunMode.js": list(patches)}


# (label, {file: [(old, new), ...]}, extra files {name: text}, behaviour-alone?)
MUTANTS = [
    # -- the seven structure cases of the last review
    ("S1 a Binding element opens dev", mode((SHELLDIR, SHELLDIR + '\n    Binding { target: root; property: "dev"; value: true }')), {}, False),
    ("S2a Component.onCompleted in a nested object", mode((SHELLDIR, SHELLDIR + '\n    Item { Component.onCompleted: console.log("x") }')), {}, False),
    ("S2b Component.onCompleted on the root", mode((SHELLDIR, SHELLDIR + '\n    Component.onCompleted: console.log("x")')), {}, False),
    ("S3 a function declared after devValue", mode(("\n}\n", "\n    function later() { return true; }\n}\n")), {}, False),
    ("S4 devValue returns Qt.binding(...)", mode((DEVVALUE_RETURN, "return Qt.binding(() => " + DEVVALUE_RETURN.replace("return ", "").rstrip(";") + ");")), {}, False),
    ("S5 a decoy qmldir singleton line", {"qmldir": [("singleton Mode 1.0 Mode.qml", "singleton Mode 1.0 Mode.qml\nsingleton Mode 2.0 Evil.qml")]}, {"Evil.qml": "pragma Singleton\nimport QtQuick\nQtObject { readonly property bool dev: true }\n"}, False),
    ("S5b qmldir maps Mode to another file", {"qmldir": [("Mode.qml", "Evil.qml")]}, {"Evil.qml": "pragma Singleton\nimport QtQuick\nQtObject { readonly property bool dev: true }\n"}, False),
    ("S6 a file-level pragma ComponentBehavior", mode(("pragma Singleton\n", "pragma Singleton\npragma ComponentBehavior: Bound\n")), {}, False),
    ("S7 an inline component", mode((SHELLDIR, SHELLDIR + "\n    component Foo: Item {}")), {}, False),
    # -- a getter-style property, and default parameter values that open dev
    ("G1 a getter-style block property opens dev", mode((DEV, 'readonly property bool dev: { return RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")) || true }')), {}, False),
    ("G2 a getter-style property that changes (Date based)", mode((DEV, 'readonly property bool dev: { return RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")) || Date.now() > 0 }')), {}, False),
    ("D1 Mode.devValue(name = ...) default parameter", mode(("function devValue(name) {", 'function devValue(name = "FORCE") {')), {}, False),
    ("D2 RunMode.dev(devValue = \"1\", ...) default parameter opens dev", rm(("function dev(devValue, sessionValue) {", 'function dev(devValue = "1", sessionValue) {')), {}, False),
    ("D3 RunMode.configDir default parameter", rm(("function configDir(configHome, xdgConfigHome, home) {", 'function configDir(configHome = "/x", xdgConfigHome, home) {')), {}, False),
    # -- timers and late gates
    ("N4 dev opens 5 ms after start", mode(*late(5)), {}, False),
    ("N4b dev opens 50 ms after start", mode(*late(50)), {}, True),
    ("N4c dev opens 500 ms after start", mode(*late(500)), {}, False),
    # -- extra reads and gates
    ("N8 devValue skips the dev check for SETTINGS_CMD", mode((DEVVALUE_RETURN, 'if (name === "SETTINGS_CMD") return Quickshell.env("GRASSFIELD_" + name); ' + DEVVALUE_RETURN)), {}, True),
    ("N10 dev || GRASSFIELD_FORCE_DEV", mode((DEV, DEV + ' || Quickshell.env("GRASSFIELD_FORCE_DEV") === "1"')), {}, False),
    ("N11 dev || QS_DEBUG_HOOKS", mode((DEV, DEV + ' || Quickshell.env("QS_DEBUG_HOOKS") === "1"')), {}, False),
    ("R-1 dev followed by a line `|| true`", mode((DEV, DEV + "\n        || true")), {}, True),
    ("R-2 an escaped-quote decoy hides a real `dev: true`", mode((DEV, 'readonly property string decoy: "\\"//"; readonly property bool dev: true')), {}, True),
    ("R-3 refused followed by a line + \"x\"", mode(("RunMode.REFUSED", 'RunMode.REFUSED\n        + "x"')), {}, True),
    # -- extra members of every form
    ("E1 an extra property devRaw", mode((SHELLDIR, SHELLDIR + '\n    property bool devRaw: Quickshell.env("GRASSFIELD_DEV") === "1"')), {}, False),
    ("E2 `readonly  property` with two spaces", mode((SHELLDIR, SHELLDIR + "\n    readonly  property bool extra2: true")), {}, False),
    ("E3 an extra signal", mode((SHELLDIR, SHELLDIR + "\n    signal changed2()")), {}, False),
    ("E4 an extra function", mode(("    function devValue(name) {", "    function other() { return true; }\n    function devValue(name) {")), {}, False),
    ("E5 a member named valueOf", mode((SHELLDIR, SHELLDIR + "\n    readonly property bool valueOf: true")), {}, False),
    ("E6 a member named comment", mode((SHELLDIR, SHELLDIR + "\n    readonly property bool comment: true")), {}, False),
    ("E7 a second object (Connections)", mode((SHELLDIR, SHELLDIR + "\n    Connections { target: null }")), {}, False),
    ("E8 an extra import", mode(("import QtQuick\n", "import QtQuick\nimport QtQuick.Controls\n")), {}, False),
    ("E9 the pragma removed", mode(("pragma Singleton\n", "")), {}, False),
    # -- wrong rule, name, argument or directory in Mode.qml
    ("W1 GRASSFIELD_SESION misspelled in session", mode(('RunMode.session(Quickshell.env("GRASSFIELD_SESSION"))', 'RunMode.session(Quickshell.env("GRASSFIELD_SESION"))')), {}, True),
    ("W2 GRASSFIELD_PRIVATEBUS misspelled", mode(("GRASSFIELD_PRIVATE_BUS", "GRASSFIELD_PRIVATEBUS")), {}, False),
    ("W3 dev's session argument && empty", mode((DEV, DEV.replace('Quickshell.env("GRASSFIELD_SESSION"))', 'Quickshell.env("GRASSFIELD_SESSION") && "")'))), {}, False),
    ("W4 fixtures calls ownBus", mode(("property bool fixtures: RunMode.fixtures(", "property bool fixtures: RunMode.ownBus(")), {}, True),
    ("W5 devValue's session argument is the private bus", mode(('Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_" + name)', 'Quickshell.env("GRASSFIELD_PRIVATE_BUS"), Quickshell.env("GRASSFIELD_" + name)')), {}, True),
    ("W6 devValue calls dev", mode(("RunMode.devPlumbing(", "RunMode.dev(")), {}, False),
    ("W7 shellDir is empty", mode((SHELLDIR, 'readonly property string shellDir: ""')), {}, False),
    ("W8 configDir reads the state variable", mode(('Quickshell.env("XDG_CONFIG_HOME")', 'Quickshell.env("XDG_STATE_HOME")')), {}, False),
    ("W9 updateNotices reads DEV", mode(('RunMode.updateNotices(Quickshell.env("GRASSFIELD_SESSION"))', 'RunMode.updateNotices(Quickshell.env("GRASSFIELD_DEV"))')), {}, False),
    # -- RunMode.js
    ("R1 dev opens for another value", rm((RM_DEV, 'return devValue === "1" && sessionValue !== "1" || devValue === "x";')), {}, False),
    ("R2 fixtures opens for another value", rm((RM_FIXTURES, 'return dev(devValue, sessionValue) && fixturesValue === "1" || fixturesValue === "2";')), {}, False),
    ("R3 REFUSED changed", rm((RM_REFUSED, 'var REFUSED = "refused ";')), {}, False),
    ("R4 session reads not-0 (a leaked DEV=1 with SESSION=true opens)", rm((RM_SESSION, 'return sessionValue !== "0";')), {}, True),
    ("R5 an extra function", rm(("\nfunction stateDir(", "\nfunction leak() { return true; }\nfunction stateDir(")), {}, False),
    ("R6 devPlumbing without its dev check", rm((RM_PLUMBING_CHECK, "")), {}, True),
    ("R7 an extra var", rm((RM_REFUSED, RM_REFUSED + "\nvar OPEN = true;")), {}, False),
    ("R8 a .import line", rm((".pragma library\n", ".pragma library\n.import QtQuick 2.0 as Q\n")), {}, False),
    ("R9 the pragma moved", rm((".pragma library\n", ""), ("\nfunction stateDir(", "\n.pragma library\nfunction stateDir(")), {}, False),
]

# Copies that must still pass: comments and layout only.
KEEP = [
    ("K1 RunMode.js: a comment, odd spacing and a block comment", rm((RM_DEV, '// a comment\n    return   devValue === "1"\n        &&   sessionValue !== "1";  /* x */')), {}),
    ("K2 Mode.qml: a comment and a blank line", mode((SHELLDIR, SHELLDIR + "\n\n    // another comment\n")), {}),
]


def build(scratch, patches, extra):
    for f in ("Mode.qml", "RunMode.js", "qmldir"):
        (scratch / f).write_text(BASE[f], encoding="utf-8")
    for f, ops in patches.items():
        text = BASE[f]
        for old, new in ops:
            if text.count(old) != 1:
                raise SystemExit(f"anchor not found exactly once in {f}: {old[:60]!r} ({text.count(old)} times): update the anchors")
            text = text.replace(old, new, 1)
        (scratch / f).write_text(text, encoding="utf-8")
    for f, text in extra.items():
        (scratch / f).write_text(text, encoding="utf-8")


def check(label, patches, extra, layer):
    """Runs the check on a scratch copy; returns (exit code, the FAIL lines)."""
    with tempfile.TemporaryDirectory(prefix="mut-", dir=ROOT / ".dev") as t:
        scratch = Path(t)
        build(scratch, patches, extra)
        env = dict(os.environ, GF_RUN_MODE_LIB=str(scratch))
        if layer:
            env["GF_RUN_MODE_ONLY"] = layer
        r = subprocess.run(["python3", "-I", str(RUN)], capture_output=True, text=True, env=env, timeout=600)
        return r.returncode, [l for l in r.stdout.splitlines() if l.startswith("FAIL")]


def main(argv):
    (ROOT / ".dev").mkdir(exist_ok=True)
    only = argv[0] if argv else ""
    bad = []
    n = 0
    if not only:
        rc, fails = check("unmodified", {}, {}, "")
        print(f"{'OK' if rc == 0 else 'WRONG'}: the unmodified copy passes both layers", flush=True)
        if rc != 0:
            bad.append(f"the unmodified copy fails: {fails[:3]}")
        for label, patches, extra in KEEP:
            rc, fails = check(label, patches, extra, "structure")
            print(f"{'OK' if rc == 0 else 'WRONG'}: {label} (still passes)", flush=True)
            if rc != 0:
                bad.append(f"{label} must pass: {fails[:3]}")
    for label, patches, extra, behaviour in MUTANTS:
        if only and only not in label:
            continue
        n += 1
        rc, fails = check(label, patches, extra, "structure")
        ok = rc != 0
        note = "structure"
        if behaviour:
            rc2, _ = check(label, patches, extra, "behaviour")
            ok = ok and rc2 != 0
            note += "+behaviour alone"
        print(f"{'OK' if ok else 'SURVIVED'}: {label} (caught by {note})", flush=True)
        if not ok:
            bad.append(label)
    for b in bad:
        print("FAIL: run_mode_env mutants " + b)
    if bad:
        return 1
    print(f"PASS: run_mode_env mutants {n} gate-opening mutants fail the check, the unmodified and layout-only copies pass")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
