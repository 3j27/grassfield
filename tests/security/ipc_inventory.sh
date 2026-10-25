#!/usr/bin/env bash
# GF-AUDIT-001 SEC-03/SEC-04: the shell's IPC surface (Quickshell IpcHandler, callable by any process of the user) is
# exactly the table in docs/specs/security.md "IPC surface", and each function is what its class says:
#   action    has a real-session caller (a binding or gesture in config/hypr/grassfield/*.lua, a session helper in
#             packaging/bin or packaging/shims, or a screen corner in shell/desktop/HotCornerActions.js) and is not gated
#   dev       refused outside a dev session: its body checks the one dev rule (ADR-0019) by an exact gate, directly or
#             through a property or a function of the same file:
#               - in a security module (shell/security/**): the call
#                 RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")), RunMode being
#                 shell/lib/RunMode.js imported by a RELATIVE path; never the qs.lib module or its Mode singleton (a
#                 qs/lib directory on QML_IMPORT_PATH would replace them: integrator decision for slice M2);
#               - elsewhere: Mode.dev (qs.lib) or VisualFixtures.dev, or that same relative RunMode.dev call;
#   fixtures  dev session AND GRASSFIELD_VISUAL_FIXTURES=1: Mode.fixtures or VisualFixtures.active (Notifications.testHooks)
# The gates themselves: RunMode.js defines dev and fixtures exactly as the rule, Mode.qml defines dev, fixtures and refused
# exactly from it (imported as "RunMode.js"), VisualFixtures.dev/active are exactly Mode.dev/Mode.fixtures.
# Also (SEC-03) no security module reads GRASSFIELD_DEV outside the gate call, imports qs.lib or reads Mode.
#   tests/security/ipc_inventory.sh             check the tree, then run the selftest
#   tests/security/ipc_inventory.sh --selftest  only the same checks on mutated copies (look-alike gates, wrong
#                                               definitions, a security module on Mode or on a local RunMode.js): each
#                                               must fail
# Static: python3 -I on the sources. Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I - "$@" <<'PY'
import glob
import os
import re
import sys

SEC_CALL = 'RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))'
RUNMODE_JS = "shell/lib/RunMode.js"
MODE_QML = "shell/lib/Mode.qml"
FIXTURES_QML = "shell/services/VisualFixtures.qml"
RULE_DEV = 'function dev(devValue, sessionValue) {\n    return devValue === "1" && sessionValue !== "1";\n}'
RULE_FIXTURES = 'function fixtures(devValue, sessionValue, fixturesValue) {\n    return dev(devValue, sessionValue) && fixturesValue === "1";\n}'
RULE_REFUSED = 'var REFUSED = "refused";'
MODE_DEV = 'readonly property bool dev: ' + SEC_CALL
MODE_FIXTURES = ('readonly property bool fixtures: RunMode.fixtures(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), '
                 'Quickshell.env("GRASSFIELD_VISUAL_FIXTURES"))')
MODE_REFUSED = 'readonly property string refused: RunMode.REFUSED'


def load():
    files = {}
    for pattern in ("shell/**/*.qml", "shell/**/*.js", "config/hypr/grassfield/*.lua", "packaging/bin/*", "packaging/shims/*"):
        for path in sorted(glob.glob(pattern, recursive=True)):
            if os.path.isfile(path):
                files[path] = open(path, encoding="utf-8", errors="replace").read()
    files["docs/specs/security.md"] = open("docs/specs/security.md", encoding="utf-8").read()
    return files


def block_end(text, start):
    depth, i = 1, start
    while depth and i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return i


def is_security(path):
    return path.startswith("shell/security/")


def runmode_aliases(text):
    return re.findall(r'^\s*\.?import\s+"([^"]+)"\s+as\s+RunMode\s*$', text, re.M)


def relative_runmode(path, text):
    """The file imports shell/lib/RunMode.js by a relative path, as RunMode, once."""
    aliases = runmode_aliases(text)
    return len(aliases) == 1 and os.path.normpath(os.path.join(os.path.dirname(path), aliases[0])) == RUNMODE_JS


def imports_qs_lib(text):
    return re.search(r"^\s*import\s+qs\.lib\b", text, re.M) is not None


def definitions(files):
    """Failures of the gate definitions (RunMode.js, Mode.qml, VisualFixtures.qml)."""
    out = []
    rm = files.get(RUNMODE_JS, "")
    if RULE_DEV not in rm or rm.count("function dev(") != 1:
        out.append("RunMode.js does not define dev exactly as the rule")
    if RULE_FIXTURES not in rm or rm.count("function fixtures(") != 1:
        out.append("RunMode.js does not define fixtures exactly as dev and GRASSFIELD_VISUAL_FIXTURES")
    if RULE_REFUSED not in rm or rm.count("REFUSED =") != 1:
        out.append('RunMode.js does not define REFUSED as "refused"')
    mode = files.get(MODE_QML, "")
    if runmode_aliases(mode) != ["RunMode.js"]:
        out.append("Mode.qml does not import RunMode.js (its own directory) as RunMode")
    for line, what in ((MODE_DEV, "dev"), (MODE_FIXTURES, "fixtures"), (MODE_REFUSED, "refused")):
        if line not in mode or len(re.findall(r"property\s+\w+\s+%s\s*:" % what, mode)) != 1:
            out.append("Mode.qml does not define %s exactly from RunMode.js" % what)
    fx = files.get(FIXTURES_QML, "")
    if not imports_qs_lib(fx) or "readonly property bool dev: Mode.dev\n" not in fx or len(re.findall(r"property\s+bool\s+dev\s*:", fx)) != 1:
        out.append("VisualFixtures.dev is not exactly Mode.dev")
    if "readonly property bool active: Mode.fixtures\n" not in fx or len(re.findall(r"property\s+bool\s+active\s*:", fx)) != 1:
        out.append("VisualFixtures.active is not exactly Mode.fixtures")
    return out


def gate_exprs(path, text, defs_ok):
    """The exact dev and fixtures gate expressions a file may use."""
    dev, fixtures = [], []
    if relative_runmode(path, text) and not (is_security(path) and imports_qs_lib(text)):
        dev.append(SEC_CALL)
    if not is_security(path) and defs_ok:
        dev.append("VisualFixtures.dev")
        fixtures.append("VisualFixtures.active")
        if imports_qs_lib(text):
            dev.append("Mode.dev")
            fixtures.append("Mode.fixtures")
    return tuple(dev), tuple(fixtures)


def prop_expr(text, prop):
    m = re.search(r"property\s+bool\s+%s\s*:\s*([^\n]+)" % re.escape(prop), text)
    return m.group(1).strip() if m else None


def fn_body(text, fn):
    m = re.search(r"function\s+%s\s*\([^)]*\)[^{]*\{" % re.escape(fn), text)
    return text[m.end():block_end(text, m.end())] if m else None


def gated_by(body, text, exprs, depth=0):
    # Exact gates (follow-up N6: a name that merely starts or ends like a gate, e.g. root.devSession reading GRASSFIELD_DEV
    # alone, MyMode.dev or Mode.devx, is not one).
    for expr in exprs:
        if re.search(r"(?<![\w.])" + re.escape(expr) + r"(?![\w.(])", body):
            return True
    # Properties read by the body (root.x or a bare x), defined in this file as exactly a gate expression.
    for prop in set(re.findall(r"(?<![\w.])(?:root\.)?([A-Za-z_]\w*)(?![\w(])", body)):
        if prop_expr(text, prop) in exprs:
            return True
    # Forwarding to a function of the same file (root.devStatus(), root.hookInvoke(id)): that function must be gated.
    if depth == 0:
        for fn in set(re.findall(r"\broot\.(\w+)\(", body)):
            inner = fn_body(text, fn)
            if inner is not None and gated_by(inner, text, exprs, 1):
                return True
    return False


def check(files):
    """(passes, failures) of every check on this set of files."""
    passes, fails = [], []
    code, own_gates = {}, []
    for path in sorted(p for p in files if p.startswith("shell/") and p.endswith(".qml")):
        src = files[path]
        for m in re.finditer(r"IpcHandler\s*\{", src):
            block = src[m.end():block_end(src, m.end())]
            target = re.search(r'target:\s*"([^"]+)"', block).group(1)
            # SEC-03: one gate. An IPC handler never reads the dev variables itself (it checks one of the exact gates).
            if re.search(r'Quickshell\.env\("GRASSFIELD_(DEV|SESSION)"\)', block.replace(SEC_CALL, "")):
                own_gates.append("%s (%s)" % (target, path))
            for f in re.finditer(r"function\s+(\w+)\s*\([^)]*\)[^{]*\{", block):
                code[(target, f.group(1))] = (path, block[f.end():block_end(block, f.end())])

    section = re.search(r"<!-- ipc-inventory:begin -->(.*?)<!-- ipc-inventory:end -->", files["docs/specs/security.md"], re.S)
    doc = {}
    if not section:
        fails.append("docs/specs/security.md has no ipc-inventory table")
    else:
        for line in section.group(1).splitlines():
            cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
            if len(cells) < 3 or cells[0] in ("Target", "") or set(cells[0]) <= {"-", ":"}:
                continue
            for fn in cells[1].split(","):
                doc[(cells[0], fn.strip().strip("`"))] = cells[2]
    missing = sorted(set(code) - set(doc))
    stale = sorted(set(doc) - set(code))
    if missing:
        fails.append("functions not in docs/specs/security.md: " + ", ".join(t + "." + f for t, f in missing))
    if stale:
        fails.append("documented functions that do not exist: " + ", ".join(t + "." + f for t, f in stale))
    if not missing and not stale:
        passes.append("%d functions of %d targets, all documented" % (len(code), len({t for t, _ in code})))

    # Real-session callers: the Hyprland config, the session helpers and shims, the screen corners. A `call <target> <fn>`
    # counts only on a line that runs `qs ipc` (comments say "call" too).
    bindings = files.get("config/hypr/grassfield/bindings.lua", "")
    callers = set(re.findall(r'shell\("(\w+)",\s*"(\w+)', bindings))
    callers |= {("switcher", f) for f in re.findall(r'(?:switcher_request|in_switcher_else)\("(\w+)"', bindings)}
    for path in sorted(files):
        if path.startswith(("config/hypr/grassfield/", "packaging/bin/", "packaging/shims/")):
            for line in files[path].splitlines():
                if "qs ipc" in line:
                    callers |= set(re.findall(r"call (\w+) (\w+)", line))
    callers |= set(re.findall(r'\["(\w+)",\s*"(\w+)"\]', files.get("shell/desktop/HotCornerActions.js", "")))

    defs = definitions(files)
    fails += defs
    if not defs:
        passes.append("the gates are defined exactly: RunMode.dev/fixtures/REFUSED, Mode.dev/fixtures/refused from RunMode.js, VisualFixtures.dev/active = Mode.dev/fixtures")

    before = len(fails)
    for key in sorted(code):
        if key not in doc:
            continue
        path, body = code[key]
        text = files[path]
        dev_exprs, fixture_exprs = gate_exprs(path, text, not defs)
        name = "%s.%s (%s)" % (key[0], key[1], path)
        cls = doc[key]
        dev_gated = gated_by(body, text, dev_exprs)
        fixtures_gated = gated_by(body, text, fixture_exprs)
        if cls == "action":
            if key not in callers:
                fails.append(name + ": class action but no binding, gesture or screen corner calls it")
            elif dev_gated or fixtures_gated:
                fails.append(name + ": class action but gated")
        elif cls == "dev":
            if not dev_gated:
                fails.append(name + ": class dev but its body checks no exact dev gate")
        elif cls == "fixtures":
            if not fixtures_gated:
                fails.append(name + ": class fixtures but its body checks no exact fixtures gate")
        else:
            fails.append(name + ": unknown class " + repr(cls))
    for key in sorted(callers - set(code)):
        fails.append("a binding or screen corner calls %s.%s, which no IpcHandler has" % key)
    if len(fails) == before:
        passes.append("every action has a real-session caller; every dev and fixtures function checks its exact gate")

    # The security modules: the gate only through the relative RunMode.js import; never qs.lib or Mode; GRASSFIELD_DEV read
    # only in the gate call (or the leaked-value warning, which tests the call's own result).
    leaks, on_mode, bad_import = [], [], []
    for path in sorted(p for p in files if is_security(p) and p.endswith((".qml", ".js"))):
        text = files[path]
        if imports_qs_lib(text) or re.search(r"(?<![\w.])Mode\.\w", text):
            on_mode.append(path)
        if (runmode_aliases(text) or re.search(r"(?<![\w.])RunMode\.", text)) and not relative_runmode(path, text):
            bad_import.append(path)
        for n, line in enumerate(text.splitlines(), 1):
            if 'Quickshell.env("GRASSFIELD_DEV")' in line and SEC_CALL not in line and "!root.devHooks" not in line:
                leaks.append("%s:%d" % (path, n))
    if on_mode:
        fails.append("security modules on the qs.lib module or the Mode singleton (use the relative RunMode.js import): " + ", ".join(on_mode))
    else:
        passes.append("no security module imports qs.lib or reads Mode")
    if bad_import:
        fails.append("security modules whose RunMode is not shell/lib/RunMode.js by a relative path: " + ", ".join(bad_import))
    else:
        passes.append("the security modules import shell/lib/RunMode.js by a relative path")
    if leaks:
        fails.append("security modules read GRASSFIELD_DEV outside the gate call: " + ", ".join(leaks))
    else:
        passes.append("security modules read GRASSFIELD_DEV only through the RunMode.dev call")
    if own_gates:
        fails.append("IPC handlers with their own dev gate (use an exact gate): " + ", ".join(own_gates))
    else:
        passes.append("no IPC handler has a dev gate of its own")
    return passes, fails


def mutate(files, path, old, new):
    copy = dict(files)
    assert copy[path].count(old) >= 1, (path, old)
    copy[path] = copy[path].replace(old, new)
    return copy


def selftest(files):
    base_pass, base_fail = check(files)
    ok = not base_fail
    print(("PASS" if ok else "FAIL") + ": ipc inventory selftest: the tree itself passes" + ("" if ok else ": " + "; ".join(base_fail)))
    sec_look = SEC_CALL.replace('"GRASSFIELD_SESSION"', '"GRASSFIELD_SESION"')
    cases = [
        ("a security gate with a look-alike variable name", "shell/security/polkit/AuthAgent.qml", SEC_CALL, sec_look),
        ("a security gate with a look-alike function", "shell/security/lock/Lock.qml", "devHooks: " + SEC_CALL, "devHooks: " + SEC_CALL.replace("RunMode.dev(", "RunMode.devx(")),
        ("a security gate behind a look-alike alias", "shell/security/idle/Idle.qml", "devHooks: " + SEC_CALL, "devHooks: My" + SEC_CALL),
        ("a security module on the Mode singleton", "shell/security/idle/Idle.qml", "devHooks: " + SEC_CALL, "devHooks: Mode.dev"),
        ("a security module importing qs.lib", "shell/security/polkit/AuthAgent.qml", "import qs.services\n", "import qs.services\nimport qs.lib\n"),
        ("a security module on a local RunMode.js", "shell/security/lock/Lock.qml", 'import "../../lib/RunMode.js" as RunMode', 'import "RunMode.js" as RunMode'),
        ("a non-security gate on a look-alike property", "shell/services/BarTone.qml", "if (!Mode.dev)", "if (!Mode.devMode)"),
        ("a non-security gate behind a look-alike singleton", "shell/platform/Capabilities.qml", "if (!Mode.dev)", "if (!MyMode.dev)"),
        ("a wrong dev definition in Mode.qml", MODE_QML, MODE_DEV, MODE_DEV.replace('Quickshell.env("GRASSFIELD_SESSION")', 'Quickshell.env("GRASSFIELD_DEV")')),
        ("a dev definition in Mode.qml that ignores the session", MODE_QML, MODE_DEV, 'readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"'),
        ("Mode.qml on another rule file", MODE_QML, 'import "RunMode.js" as RunMode', 'import "OtherMode.js" as RunMode'),
        ("a wrong rule in RunMode.js", RUNMODE_JS, RULE_DEV, 'function dev(devValue, sessionValue) {\n    return devValue === "1";\n}'),
        ("a wrong fixtures rule in RunMode.js", RUNMODE_JS, RULE_FIXTURES, 'function fixtures(devValue, sessionValue, fixturesValue) {\n    return fixturesValue === "1";\n}'),
        ("VisualFixtures.dev not Mode.dev", FIXTURES_QML, "readonly property bool dev: Mode.dev\n", "readonly property bool dev: Mode.session\n"),
        ("an IPC handler reading GRASSFIELD_DEV itself", "shell/services/BarTone.qml", "if (!Mode.dev)", 'if (Quickshell.env("GRASSFIELD_DEV") !== "1")'),
    ]
    for label, path, old, new in cases:
        _, fails = check(mutate(files, path, old, new))
        caught = bool(fails)
        ok = ok and caught
        print(("PASS" if caught else "FAIL") + ": ipc inventory selftest: %s is caught%s" % (label, (" (" + fails[0][:140] + ")") if caught else ""))
    return ok


files = load()
if sys.argv[1:] == ["--selftest"]:
    sys.exit(0 if selftest(files) else 1)
passes, fails = check(files)
for p in passes:
    print("PASS: ipc inventory " + p)
for f in fails:
    print("FAIL: ipc inventory " + f)
sys.exit(0 if selftest(files) and not fails else 1)
PY
