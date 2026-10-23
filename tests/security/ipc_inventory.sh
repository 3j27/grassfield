#!/usr/bin/env bash
# GF-AUDIT-001 SEC-03/SEC-04: the shell's IPC surface (Quickshell IpcHandler, callable by any process of the user) is
# exactly the table in docs/specs/security.md "IPC surface", and each function is what its class says:
#   action    has a real-session caller (a binding or gesture in config/hypr/grassfield/*.lua, a session helper in
#             packaging/bin or packaging/shims, or a screen corner in shell/desktop/HotCornerActions.js) and is not gated
#   dev       refused outside a dev session: its body checks the one dev gate (shell/services/DevGate.js, directly,
#             through VisualFixtures.dev, or a dev* function of the singleton)
#   fixtures  dev session AND GRASSFIELD_VISUAL_FIXTURES=1 (VisualFixtures.active, Notifications.testHooks)
# Also (SEC-03) no security module reads GRASSFIELD_DEV outside the DevGate call. Static: python3 -I on the sources.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I - <<'PY'
import glob
import re
import sys

fail = False


def ok(msg):
    print("PASS: ipc inventory " + msg)


def bad(msg):
    global fail
    fail = True
    print("FAIL: ipc inventory " + msg)


def block_end(text, start):
    depth, i = 1, start
    while depth and i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return i


# --- the code: every IpcHandler function and its body ---
code = {}
own_gates = []
for path in sorted(glob.glob("shell/**/*.qml", recursive=True)):
    src = open(path, encoding="utf-8").read()
    for m in re.finditer(r"IpcHandler\s*\{", src):
        block = src[m.end():block_end(src, m.end())]
        target = re.search(r'target:\s*"([^"]+)"', block).group(1)
        # SEC-03: one gate. An IPC handler never reads the dev variables itself (it checks DevGate or VisualFixtures).
        stripped = block.replace('DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))', "")
        if re.search(r'Quickshell\.env\("GRASSFIELD_(DEV|SESSION)"\)', stripped):
            own_gates.append("%s (%s)" % (target, path))
        for f in re.finditer(r"function\s+(\w+)\s*\([^)]*\)[^{]*\{", block):
            body = block[f.end():block_end(block, f.end())]
            code[(target, f.group(1))] = (path, body)

# --- the documented table ---
spec = open("docs/specs/security.md", encoding="utf-8").read()
section = re.search(r"<!-- ipc-inventory:begin -->(.*?)<!-- ipc-inventory:end -->", spec, re.S)
doc = {}
if not section:
    bad("docs/specs/security.md has no ipc-inventory table")
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
    bad("functions not in docs/specs/security.md: " + ", ".join(t + "." + f for t, f in missing))
if stale:
    bad("documented functions that do not exist: " + ", ".join(t + "." + f for t, f in stale))
if not missing and not stale:
    ok("%d functions of %d targets, all documented" % (len(code), len({t for t, _ in code})))

# --- real-session callers: the Hyprland config, the session helpers and shims (packaging/bin, packaging/shims), the
# screen corners. A `call <target> <fn>` counts only on a line that runs `qs ipc` (comments say "call" too).
bindings = open("config/hypr/grassfield/bindings.lua", encoding="utf-8").read()
callers = set(re.findall(r'shell\("(\w+)",\s*"(\w+)', bindings))
callers |= {("switcher", f) for f in re.findall(r'(?:switcher_request|in_switcher_else)\("(\w+)"', bindings)}
scanned = sorted(glob.glob("config/hypr/grassfield/*.lua")) + sorted(glob.glob("packaging/bin/*")) + sorted(glob.glob("packaging/shims/*"))
for path in scanned:
    for line in open(path, encoding="utf-8", errors="replace"):
        if "qs ipc" in line:
            callers |= set(re.findall(r"call (\w+) (\w+)", line))
corners = open("shell/desktop/HotCornerActions.js", encoding="utf-8").read()
callers |= set(re.findall(r'\["(\w+)",\s*"(\w+)"\]', corners))

DEV_GATES = ("VisualFixtures.dev", "DevGate.", "root.devHooks", "root.dev")
FIXTURE_GATES = ("VisualFixtures.active", "root.hook")
for key in sorted(code):
    if key not in doc:
        continue
    path, body = code[key]
    name = "%s.%s (%s)" % (key[0], key[1], path)
    cls = doc[key]
    gated = any(g in body for g in DEV_GATES + FIXTURE_GATES)
    if cls == "action":
        if key not in callers:
            bad(name + ": class action but no binding, gesture or screen corner calls it")
        elif gated:
            bad(name + ": class action but gated")
    elif cls == "dev":
        if not any(g in body for g in DEV_GATES):
            bad(name + ": class dev but its body checks no dev gate")
    elif cls == "fixtures":
        if not any(g in body for g in FIXTURE_GATES):
            bad(name + ": class fixtures but its body checks no fixtures gate")
    else:
        bad(name + ": unknown class " + repr(cls))
for key in sorted(callers - set(code)):
    bad("a binding or screen corner calls %s.%s, which no IpcHandler has" % key)
if not fail:
    ok("every action has a real-session caller; every dev and fixtures function checks its gate")

# --- the gates themselves ---
fixtures = open("shell/services/VisualFixtures.qml", encoding="utf-8").read()
if 'readonly property bool dev: DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))' in fixtures:
    ok("VisualFixtures.dev is DevGate.allowed")
else:
    bad("VisualFixtures.dev is not DevGate.allowed(GRASSFIELD_DEV, GRASSFIELD_SESSION)")
gate_call = 'DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))'
leaks = []
for path in sorted(glob.glob("shell/security/**/*.qml", recursive=True)):
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if 'Quickshell.env("GRASSFIELD_DEV")' in line and gate_call not in line and "!root.devHooks" not in line:
            leaks.append("%s:%d" % (path, n))
if leaks:
    bad("security modules read GRASSFIELD_DEV outside the dev gate: " + ", ".join(leaks))
else:
    ok("security modules read GRASSFIELD_DEV only through DevGate.allowed")
if own_gates:
    bad("IPC handlers with their own dev gate (use DevGate.allowed or VisualFixtures.dev): " + ", ".join(own_gates))
else:
    ok("no IPC handler has a dev gate of its own")
sys.exit(1 if fail else 0)
PY
