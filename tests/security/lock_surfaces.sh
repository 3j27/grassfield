#!/usr/bin/env bash
# GF-AUDIT-001 GF-116 (DT-08), static part: while the session is locked no shell surface opens, whichever path asks.
# The runtime part runs the real controllers offscreen (tests/security/lock_surfaces/shell.qml: Search, Apps, Notification
# Center, Overview, every Popups kind). This script checks, in the sources, what offscreen cannot run:
#   wiring    shell.qml mirrors Lock.locked into SessionState.locked; Overview and Switcher get the lock state;
#   refusal   each surface's entry point refuses while locked as its first decision: Popups.open, Search.show,
#             AppsController.show, Overview.show, Notifications.toggleCenter/openWidgetGallery, Dock.enterKeyboardMode,
#             the four window commands (IPC target "windows"), Switcher.step;
#   closing   each surface closes when the lock engages (Popups, Search, Apps, Notification Center, Overview, Dock keyboard
#             mode, Switcher);
#   routes    every IPC action that opens a surface goes through that entry point (search toggle, apps toggle/open,
#             overview toggle/open, notifications toggleCenter, menubar open/panel, dock keyboard), and the screen corners
#             call those IPC actions;
#   polkit    a polkit sheet that arrives while locked is neither mapped nor given the keyboard until the unlock.
# Self-test: the checker fails on a copy of the tree with one refusal removed (mutation). Plain shell test: PASS/FAIL lines.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
pass() { echo "PASS: lock surfaces $*"; }
bad() { echo "FAIL: lock surfaces $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/lock-surfaces.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/check.py" <<'PY'
import re, sys

root = sys.argv[1]
problems, oks = [], []

def read(path):
    with open(f"{root}/{path}", encoding="utf-8") as f:
        return f.read()

def block_after(text, start):
    # The text between the first "{" at or after `start` and its matching "}" (comments and strings are rare enough here).
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise ValueError("unbalanced")

def function(text, name):
    m = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\(", text)
    return block_after(text, m.end()) if m else None

def ipc(text, target):
    m = re.search(r'IpcHandler\s*\{\s*target:\s*"' + re.escape(target) + '"', text)
    return block_after(text, m.start()) if m else None

def code(body):
    return "\n".join(l.split("//", 1)[0] for l in body.split("\n"))

def expect(what, ok):
    (oks if ok else problems).append(what)

def first_decision(path, name, needle, text=None, lines=4):
    body = function(text if text is not None else read(path), name)
    if body is None:
        expect(f"{path}: function {name} exists", False)
        return
    head = "\n".join(l for l in code(body).split("\n") if l.strip())
    head = "\n".join(head.split("\n")[:lines])
    expect(f"{path}: {name}() refuses while locked first ({needle})", needle in head)

shell = read("shell/shell.qml")
expect("shell.qml binds SessionState.locked to Lock.locked",
       re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"locked\"\s*value:\s*Lock\.locked\s*\}", shell) is not None)
expect("shell.qml gives the Overview the lock state", re.search(r"Overview\s*\{[^}]*locked:\s*Lock\.lockState\s*!==\s*\"unlocked\"", shell, re.S) is not None)
expect("shell.qml gives the Switcher the lock state", re.search(r"Switcher\s*\{[^}]*locked:\s*Lock\.lockState\s*!==\s*\"unlocked\"", shell, re.S) is not None)

state = read("shell/services/SessionState.qml")
refuses = function(state, "refuses")
expect("SessionState.refuses() returns true while locked", refuses is not None and re.search(r"if\s*\(!locked\)\s*return false;", refuses) is not None and "return true;" in refuses)

R = "SessionState.refuses("
first_decision("shell/services/Popups.qml", "open", R)
first_decision("shell/search/Search.qml", "show", R)
first_decision("shell/launchpad/AppsController.qml", "show", R)
first_decision("shell/overview/Overview.qml", "show", R)
first_decision("shell/notifications/Notifications.qml", "openWidgetGallery", R)
first_decision("shell/dock/Dock.qml", "enterKeyboardMode", R)
toggle = function(read("shell/notifications/Notifications.qml"), "toggleCenter") or ""
opening = code(toggle).split("closeCenter();", 1)[-1]
expect("shell/notifications/Notifications.qml: toggleCenter() refuses before it opens", R in opening and opening.index(R) < opening.index("centerOpen = true"))
compositor = read("shell/platform/Compositor.qml")
windows = ipc(compositor, "windows")
for name in ("minimize", "tile", "hide", "cycleApp"):
    first_decision("shell/platform/Compositor.qml", f"windows.{name}", R) if windows is None else first_decision("shell/platform/Compositor.qml", name, R, text=windows, lines=2)
# The plugin's minimize-request event (the titlebar button and, since GF-056 P8, a tagged window's own minimize button)
# moves nothing behind the lock either.
first_decision("shell/platform/Compositor.qml", "minimizeByAddress", R, text=compositor, lines=2)
first_decision("shell/switcher/Switcher.qml", "step", "if (locked)", lines=8)
# Review of 1d2c856: the desktop's context menu, its attribution card and the widget menu (an Overlay layer with the
# keyboard) also refuse and close.
first_decision("shell/desktop/IconsView.qml", "openMenu", R)
first_decision("shell/desktop/IconsView.qml", "openAbout", R)
widgets = code(read("shell/desktop/DesktopWidgets.qml"))
m = re.search(r"onMenuRequested:\s*\(px, py\)\s*=>\s*\{", widgets)
expect("shell/desktop/DesktopWidgets.qml: the widget menu refuses while locked first", m is not None and R in "\n".join(l for l in block_after(widgets, m.start()).split("\n") if l.strip())[:200])

# Closing when the lock engages.
def closes(path, pattern, what):
    expect(f"{path}: {what}", re.search(pattern, code(read(path)), re.S) is not None)
closes("shell/services/Popups.qml", r"target:\s*SessionState.*?onLockedChanged.*?if\s*\(SessionState\.locked\)\s*root\.close\(\)", "closes when the session locks")
closes("shell/search/Search.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.hide\(\)", "closes when the session locks")
closes("shell/launchpad/AppsController.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.hide\(\)", "closes when the session locks")
closes("shell/notifications/Notifications.qml", r"onSessionLockedChanged:.*?sessionLocked\s*&&\s*centerOpen.*?closeCenter\(\)", "closes the Center when the session locks")
closes("shell/overview/Overview.qml", r"onLockedChanged:.*?if\s*\(locked\)\s*requestCloseForOther\(\)", "closes when the session locks")
closes("shell/dock/Dock.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?keyboardMode\s*=\s*false", "leaves keyboard mode when the session locks")
closes("shell/switcher/Switcher.qml", r"onLockedChanged:.*?if\s*\(locked\)\s*cancel\(\)", "ends when the session locks")
closes("shell/desktop/IconsView.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?root\.closeMenu\(\"outside\"\).*?root\.closeAbout\(\"outside\"\)", "closes its menu and card when the session locks")
closes("shell/desktop/DesktopWidgets.qml", r"target:\s*SessionState.*?onLockedChanged.*?SessionState\.locked.*?scope\.closeMenu\(\)", "closes the widget menu when the session locks")

# IPC actions route through the refusing entry points.
def route(path, target, name, pattern):
    handler = ipc(read(path), target)
    body = function(handler, name) if handler else None
    expect(f"IPC {target} {name} goes through {pattern}", body is not None and re.search(pattern, code(body)) is not None)
route("shell/search/Search.qml", "search", "toggle", r"root\.toggle\(\)")
route("shell/search/Search.qml", "search", "open", r"root\.show\(")
route("shell/launchpad/AppsController.qml", "apps", "toggle", r"root\.toggle\(\)")
route("shell/launchpad/AppsController.qml", "apps", "open", r"root\.show\(\)")
route("shell/overview/Overview.qml", "overview", "toggle", r"root\.toggle\(\)")
route("shell/overview/Overview.qml", "overview", "open", r"root\.show\(\)")
route("shell/notifications/Notifications.qml", "notifications", "toggleCenter", r"root\.toggleCenter\(")
route("shell/menubar/MenuBar.qml", "menubar", "open", r"bar\.popup\(")
route("shell/menubar/MenuBar.qml", "menubar", "panel", r"Popups\.open\(")
route("shell/dock/Dock.qml", "dock", "keyboard", r"root\.enterKeyboardMode\(\)")
search =read("shell/search/Search.qml")
expect("Search.toggle() opens only through show()", re.search(r"else\s+show\(", code(function(search, "toggle") or "")) is not None)
apps = read("shell/launchpad/AppsController.qml")
expect("AppsController.toggle() opens only through show()", re.search(r"else\s+show\(\)", code(function(apps, "toggle") or "")) is not None)
overview = read("shell/overview/Overview.qml")
expect("Overview.toggle() opens only through show()", re.search(r"else\s+show\(\)", code(function(overview, "toggle") or "")) is not None)
popups = read("shell/services/Popups.qml")
for name in ("toggle", "openCentered"):
    expect(f"Popups.{name}() opens only through open()", re.search(r"\bopen\(", code(function(popups, name) or "")) is not None and "kind = " not in code(function(popups, name) or ""))
corners = read("shell/desktop/HotCornerActions.js")
expect("screen corners call the IPC actions (overview toggle, apps toggle) or Notifications.toggleCenter",
       '["overview", "toggle"]' in corners and '["apps", "toggle"]' in corners and '"notifications"' in corners)

# Polkit: held behind the lock.
agent = code(read("shell/security/polkit/AuthAgent.qml"))
expect("polkit sheet: shown only while active and unlocked", re.search(r"property bool shown:\s*dialogModel\.active\s*&&\s*!SessionState\.locked", agent) is not None)
expect("polkit sheet: mapped only when shown", re.search(r"\bvisible:\s*shown\b", agent) is not None)
expect("polkit sheet: takes the keyboard only when shown and not held", re.search(r"keyboardFocus:\s*win\.takesKeys\s*\?\s*WlrKeyboardFocus\.Exclusive", agent) is not None
       and re.search(r"property bool takesKeys:\s*shown\s*&&\s*\(!root\.heldByLock\s*\|\|\s*root\.userFocused\)", agent) is not None)
# Review of 1d2c856: a request held behind the lock takes the keyboard only after a click past the guard, never at once.
expect("polkit sheet: a held request takes the keyboard only after a click past the guard",
       re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused.*?if\s*\(!dialogModel\.heldClickAccepted\(\)\)\s*return;.*?root\.userFocused\s*=\s*true", agent, re.S) is not None
       and re.search(r"onShownChanged:\s*\{\s*if\s*\(shown\)\s*dialogModel\.noteShown\(\);", agent) is not None)
expect("polkit sheet: a request arriving while locked, or just after an unlock, is held",
       re.search(r"heldByLock\s*=\s*dialogModel\.active\s*&&\s*\(follows\s*\|\|\s*dialogModel\.arrivesHeld\(SessionState\.locked\s*\|\|\s*SessionState\.saverShown\)\);", agent) is not None
       and re.search(r"if\s*\(!SessionState\.locked\)\s*\{\s*dialogModel\.noteUnlock\(\);", agent) is not None)
# Review of 6e24d36: the unlock hold and the click guard are timed by Timers (monotonic), never by the wall clock; the
# agent reads Date.now() only for the arrival time the notice shows.
model = code(read("shell/security/polkit/AuthDialogModel.qml"))
bodies = {n: code(function(model, n) or "") for n in ("noteUnlock", "noteShown", "heldClickAccepted", "arrivesHeld")}
expect("polkit holds: timed by Timers, never by the wall clock",
       len(re.findall(r"\bDate\b", agent)) == 1 and re.search(r"requestStartedAt\s*=\s*dialogModel\.active\s*\?\s*new Date\(\)\s*:\s*null", agent) is not None
       and not any(re.search(r"\bDate\b", b) for b in bodies.values())
       and re.search(r"property Timer unlockHold:\s*Timer\s*\{\s*interval:\s*root\.heldAfterUnlockMs\s*\}", model) is not None
       and re.search(r"property Timer clickGuard:\s*Timer\s*\{\s*interval:\s*root\.heldGuardMs\s*\}", model) is not None
       and re.search(r"^\s*unlockHold\.restart\(\);\s*$", bodies["noteUnlock"], re.M) is not None
       and re.search(r"priv\.shown\s*=\s*true;\s*clickGuard\.restart\(\);", bodies["noteShown"]) is not None
       and re.search(r"^\s*return\s+priv\.shown\s*&&\s*!clickGuard\.running;\s*$", bodies["heldClickAccepted"], re.M) is not None
       and re.search(r"^\s*return\s+locked\s*\|\|\s*unlockHold\.running;\s*$", bodies["arrivesHeld"], re.M) is not None
       and re.search(r"^\s*clickGuard\.restart\(\);\s*$", code(function(model, "noteUncovered") or ""), re.M) is not None)
# ADR-0032 (owner decision 2026-10-26): the screen saver holds a request as the lock does, its waking click answers nothing,
# and the click guard starts over when it ends.
saver_hold = code(function(agent, "onSaverShownChanged") or "")
expect("polkit sheet: a request open when the screen saver comes up is held, its field emptied (nothing but the lock and no request return first)",
       re.match(r"\s*if\s*\(!dialogModel\.active\s*\|\|\s*SessionState\.locked\)\s*return;\s*if\s*\(SessionState\.saverShown\)\s*\{", saver_hold) is not None
       and re.search(r"if\s*\(SessionState\.saverShown\)\s*\{.*?root\.heldByLock\s*=\s*true;\s*root\.userFocused\s*=\s*false;\s*dialogModel\.clearRequested\(\);", saver_hold, re.S) is not None)
# Review of f513b3b (MEDIUM-1): the link that carries the saver's state, and who may give the keyboard or set the hold.
expect("shell.qml binds SessionState.saverShown to the screen saver's shown",
       re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"saverShown\"\s*value:\s*saver\.shown\s*\}", shell) is not None
       and re.search(r"\bSaver\s*\{\s*id:\s*saver\b", shell) is not None)
expect("polkit sheet: only a click past the guard gives the keyboard (one userFocused = true)",
       len(re.findall(r"userFocused\s*=\s*true", agent)) == 1)
expect("polkit sheet: the hold is set only on an arrival, a lock and the screen saver",
       len(re.findall(r"\bheldByLock\s*=(?!=)", agent)) == 3)
# Review of f513b3b (MEDIUM-2): a queued request that follows another in the same sheet is a new arrival, held.
flow_changed = code(block_after(agent, re.search(r"onFlowChanged:", agent).end()) if re.search(r"onFlowChanged:", agent) else "")
arrive = code(function(agent, "arrive") or "")
expect("polkit sheet: a queued request that follows another is held, emptied, its guard started over",
       re.search(r"const follows\s*=\s*root\.shownFlow\s*!==\s*null\s*&&\s*flow\s*!==\s*null\s*&&\s*flow\s*!==\s*root\.shownFlow;\s*root\.shownFlow\s*=\s*flow;\s*if\s*\(follows\)\s*root\.arrive\(true\);", flow_changed) is not None
       and re.search(r"onActiveChanged:\s*root\.arrive\(false\)", agent) is not None
       and re.search(r"if\s*\(follows\)\s*\{\s*dialogModel\.clearRequested\(\);\s*dialogModel\.noteShown\(\);\s*\}", arrive) is not None)
expect("polkit sheet: the click guard starts over when the screen saver ends",
       re.search(r"else if\s*\(root\.heldByLock\)\s*\{\s*dialogModel\.noteUncovered\(\);", saver_hold) is not None)
expect("polkit sheet: a press goes nowhere while the screen saver shows",
       re.search(r"MouseArea\s*\{\s*anchors\.fill:\s*parent\s*enabled:\s*SessionState\.saverShown\s*acceptedButtons:\s*Qt\.AllButtons\s*onPressed:\s*mouse\s*=>\s*mouse\.accepted\s*=\s*true\s*onWheel:\s*wheel\s*=>\s*wheel\.accepted\s*=\s*true\s*\}", agent) is not None)
expect("polkit sheet: a request open when the lock engages is held", re.search(r"else if\s*\(dialogModel\.active\)\s*\{\s*root\.heldByLock\s*=\s*true", agent) is not None)
expect("polkit sheet: a held request is not focused when it appears", re.search(r"if\s*\(shown\s*&&\s*!root\.heldByLock\)\s*dialog\.focusField\(\)", agent) is not None)
expect("polkit sheet: the typed text is dropped when the lock hides it", re.search(r"onShownChanged:.*?clearRequested\(\)", agent, re.S) is not None)

# Review of 2dfd992: no wall clock in shell/security. Every delay is a Qt Timer (monotonic); the only Date left is the
# arrival time the held polkit sheet prints. Any other `Date` (Date.now, new Date, Date.parse), getTime, valueOf or
# performance.now in the code (comments excluded) fails.
import os
def nocomments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", l) for l in text.split("\n"))
allowed_dates = {
    "shell/security/lock/LockView.qml": ["WallClock {\n        id: clock\n    }"],
    "shell/security/polkit/AuthAgent.qml": ["root.requestStartedAt = dialogModel.active ? new Date() : null;"],
    "shell/security/polkit/AuthDialogModel.qml": ["Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat))"],
}
clock_hits = []
for base, _, files in os.walk(f"{root}/shell/security"):
    for name in sorted(files):
        if not name.endswith((".qml", ".js")):
            continue
        rel = os.path.relpath(os.path.join(base, name), root)
        text = nocomments(read(rel))
        spans = []
        for snippet in allowed_dates.get(rel, []):
            i = text.find(snippet)
            if i >= 0:
                spans.append((i, i + len(snippet)))
        for m in re.finditer(r"\bDate\b|\bSystemClock\b|\bWallClock\b|\bgetTime\s*\(|\bperformance\s*\.\s*now\b|\bvalueOf\s*\(", text):
            if not any(a <= m.start() < b for a, b in spans):
                clock_hits.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1} {m.group(0)}")
# The lock screen's clock (review of eee45cc; WallClock since cf6d3df, and a WallClock anywhere else in shell/security is a
# wall clock too) only feeds the two displayed texts.
lockview = nocomments(read("shell/security/lock/LockView.qml"))
clock_uses = re.findall(r"\bclock\s*\.\s*\w+", lockview)
if not (len(clock_uses) == 2 and lockview.count("FixedTime.date(clock.date)") == 2):
    clock_hits.append("LockView.qml clock uses " + ", ".join(clock_uses))
expect("no wall clock in shell/security (" + ", ".join(clock_hits) + ")", not clock_hits)
lock = code(read("shell/security/lock/Lock.qml"))
expect("lock ownership check: the grace window after a confirmed lock is a single-shot Timer",
       re.search(r"Timer\s*\{\s*id:\s*secureGrace\s+interval:\s*ownershipProbe\.verifyGraceMs\s*\}", lock) is not None
       and re.search(r"onSecureStateChanged:\s*\{\s*if\s*\(secure\)\s*\{[^}]*?secureGrace\.restart\(\);", lock) is not None
       and re.search(r"if\s*\(!holding\s*\|\|\s*!hyprland\s*\|\|\s*secureGrace\.running\)\s*return;", code(function(lock, "verify") or "")) is not None
       and re.search(r"if\s*\(!holding\s*\|\|\s*secureGrace\.running\)\s*\{", code(function(lock, "checkOwnership") or "")) is not None)
# Review of eee45cc: the window is exactly 500 ms and nothing else touches the Timer (a 1 h or 0 ms grace, or a
# `secureGrace.repeat = true` after the first lock, passed every offscreen test). Every mention of secureGrace is its id,
# one restart() and the two `running` reads.
grace_uses = re.findall(r"\bsecureGrace\b(?:\s*\.\s*\w+(?:\s*\(\s*\))?)?", lock)
expect("lock ownership check: the grace is 500 ms and only restart() and `running` touch its Timer (" + ", ".join(grace_uses) + ")",
       re.search(r"Timer\s*\{\s*id:\s*ownershipProbe\b[^}]*?^\s*readonly property int verifyGraceMs: 500[ \t]*\n\s*(\}|[A-Za-z_][\w.]*\s*:|readonly\s|property\s|function\s)", lock, re.S | re.M) is not None
       and len(re.findall(r"\bverifyGraceMs\s*:", lock)) == 1
       and sorted(re.sub(r"\s+", "", u) for u in grace_uses) == sorted(["secureGrace", "secureGrace.restart()", "secureGrace.running", "secureGrace.running"]))
sleep = code(read("shell/security/idle/SleepInhibitor.qml"))
idle = code(read("shell/security/idle/IdleModel.js"))
# Reviews of 2dfd992 and eee45cc: a child is healthy only when its health Timer saw it running FAST_EXIT_MS AND it showed
# progress (the inhibitor's "held", the watcher's first line); one without progress within PROGRESS_BUDGET_MS is stopped
# and counted as a failure.
expect("sleep inhibitor: a child is healthy only after FAST_EXIT_MS with progress; a hung one is a failure",
       re.search(r"^var PROGRESS_BUDGET_MS = 35000;$", idle, re.M) is not None
       and re.search(r'if\s*\(!watcher\.progressed && IdleModel\.watcherSubscribed\(line\)\)', sleep) is not None
       and re.search(r'return typeof line === "string" && line\.indexOf\("The name org\.freedesktop\.login1 is owned by "\) === 0;', code(function(idle, "watcherSubscribed") or "")) is not None
       and re.search(r"return ranLong === true \? 0 : n \+ 1;", code(function(idle, "failuresAfterRun") or "")) is not None
       and '"systemd-inhibit", "--what=sleep", "--mode=delay", "--who=Grassfield", "--why=" + qsTr("Lock the screen before sleep"), "sh", "-c", "echo held; exec cat"]' in sleep
       and re.search(r'if\s*\(line === "held" && !inhibitor\.progressed\)', sleep) is not None
       and all(re.search(r"root\." + c + r"Failures\s*=\s*IdleModel\.failuresAfterRun\(root\." + c + r"Failures,\s*ranLong\);", sleep) is not None
               and re.search(r"if\s*\(" + c + r"\.running\s*&&\s*" + c + r"\.progressed\)\s*\{\s*" + c + r"\.ranLong\s*=\s*true;", sleep) is not None
               and re.search(c + r"\.progressed\s*=\s*true;\s*" + c + r"Progress\.stop\(\);.*?if\s*\(" + c + r"\.running\s*&&\s*!" + c + r"Healthy\.running\)\s*\{\s*" + c + r"\.ranLong\s*=\s*true;", sleep, re.S) is not None
               and re.search(r"onStarted:\s*\{\s*ranLong\s*=\s*false;\s*progressed\s*=\s*false;\s*" + c + r"Healthy\.restart\(\);\s*" + c + r"Progress\.restart\(\);", sleep) is not None
               and re.search(r"Timer\s*\{\s*id:\s*" + c + r"Progress\s+interval:\s*IdleModel\.PROGRESS_BUDGET_MS\s+onTriggered:\s*\{\s*if\s*\(" + c + r"\.running\s*&&\s*!" + c + r"\.progressed\)\s*\{[^}]*?" + c + r"\.running\s*=\s*false;", sleep) is not None
               for c in ("inhibitor", "watcher")))

for o in oks:
    print("OK " + o)
for p in problems:
    print("PROBLEM " + p)
sys.exit(1 if problems else 0)
PY

out=$(python3 -I "$tmp/check.py" "$root" 2>&1)
rc=$?
while IFS= read -r line; do
  case $line in
    "OK "*) pass "${line#OK }" ;;
    "PROBLEM "*) bad "${line#PROBLEM }" ;;
    *) [[ -n $line ]] && bad "checker: $line" ;;
  esac
done <<<"$out"
((rc == 0)) || bad "checker exit $rc"

# Mutation: the checker must fail when one refusal is removed (a copy of the files it reads).
mut=$tmp/mutant
for f in shell/shell.qml shell/services/SessionState.qml shell/services/Popups.qml shell/search/Search.qml shell/launchpad/AppsController.qml \
  shell/overview/Overview.qml shell/notifications/Notifications.qml shell/dock/Dock.qml shell/platform/Compositor.qml shell/switcher/Switcher.qml \
  shell/menubar/MenuBar.qml shell/desktop/HotCornerActions.js shell/security/polkit/AuthAgent.qml shell/security/polkit/AuthDialogModel.qml \
  shell/desktop/IconsView.qml shell/desktop/DesktopWidgets.qml; do
  mkdir -p "$mut/$(dirname "$f")"
  cp "$root/$f" "$mut/$f"
done
cp -a "$root/shell/security" "$mut/shell/" # the wall-clock scan reads every file of shell/security
python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1 && pass "mutation: the unchanged copy passes" || bad "mutation: the unchanged copy fails"
for case_ in 'shell/dock/Dock.qml#SessionState.refuses("dock keyboard")#false' \
  'shell/desktop/DesktopWidgets.qml#SessionState.refuses("widget menu")#false' \
  'shell/desktop/IconsView.qml#root.closeMenu("outside");#root.closeAbout("outside");' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows cycleApp")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows minimize request")#false' \
  'shell/services/Popups.qml#SessionState.refuses("popup " + popupKind)#false' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && !SessionState.locked#dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#shown && (!root.heldByLock || root.userFocused)#shown' \
  'shell/security/polkit/AuthAgent.qml#if (shown && !root.heldByLock)#if (shown)' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.arrivesHeld(SessionState.locked || SessionState.saverShown)#SessionState.locked || SessionState.saverShown' \
  'shell/security/polkit/AuthAgent.qml#arrivesHeld(SessionState.locked || SessionState.saverShown)#arrivesHeld(SessionState.locked)' \
  'shell/security/polkit/AuthAgent.qml#                root.heldByLock = true;\n                root.userFocused = false;\n                dialogModel.clearRequested();#                root.userFocused = false;' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUncovered();#;' \
  'shell/security/polkit/AuthAgent.qml#enabled: SessionState.saverShown#enabled: false' \
  'shell/security/polkit/AuthAgent.qml#acceptedButtons: Qt.AllButtons#acceptedButtons: Qt.LeftButton' \
  'shell/shell.qml#        property: "saverShown"\n        value: saver.shown#        property: "saverShown"\n        value: false' \
  'shell/security/polkit/AuthAgent.qml#if (!dialogModel.active || SessionState.locked)#if (!dialogModel.active || SessionState.locked || !SessionState.saverShown)' \
  'shell/security/polkit/AuthAgent.qml#        root.userFocused = false;\n        root.requestStartedAt#        root.userFocused = true;\n        root.requestStartedAt' \
  'shell/security/polkit/AuthAgent.qml#const follows = root.shownFlow !== null#const follows = false && root.shownFlow !== null' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && (follows || #dialogModel.active && (' \
  'shell/security/polkit/AuthAgent.qml#            dialogModel.clearRequested();\n            dialogModel.noteShown();#            dialogModel.clearRequested();' \
  'shell/security/polkit/AuthDialogModel.qml#        clickGuard.restart();\n    }\n\n    // A request is held#    }\n\n    // A request is held' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUnlock();#root.unlockedAt = Date.now();' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteShown();#root.shownAt = Date.now();' \
  'shell/security/polkit/AuthDialogModel.qml#return locked || unlockHold.running;#return locked || Date.now() - priv.unlockedAt < heldAfterUnlockMs;' \
  'shell/security/polkit/AuthDialogModel.qml#return priv.shown && !clickGuard.running;#return !clickGuard.running;' \
  'shell/security/polkit/AuthAgent.qml#active ? new Date() : null#active ? Date.now() : 0' \
  'shell/security/lock/Lock.qml#secureGrace.restart();#root.securedAt = Date.now();' \
  'shell/security/lock/Lock.qml#if (!holding || secureGrace.running) {#if (!holding || Date.now() - root.securedAt < 500) {' \
  'shell/security/lock/Lock.qml#if (!holding || !hyprland || secureGrace.running)#if (!holding || !hyprland)' \
  'shell/security/idle/SleepInhibitor.qml#IdleModel.failuresAfterRun(root.inhibitorFailures, ranLong)#IdleModel.failuresAfterRun(root.inhibitorFailures, true)' \
  'shell/security/idle/SleepInhibitor.qml#            if (watcher.running && watcher.progressed) {#            if (watcher.running) {' \
  'shell/security/idle/SleepInhibitor.qml#            if (inhibitor.running && !inhibitor.progressed) {#            if (false) {' \
  'shell/security/idle/SleepInhibitor.qml#"sh", "-c", "echo held; exec cat"#"cat"' \
  'shell/security/idle/IdleModel.js#var PROGRESS_BUDGET_MS = 35000;#var PROGRESS_BUDGET_MS = 10000;' \
  'shell/security/idle/SleepInhibitor.qml#if (!watcher.progressed && IdleModel.watcherSubscribed(line)) {#if (!watcher.progressed) {' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 500\n            * 7200' \
  'shell/security/lock/LockView.qml#            text: Qt.formatTime(FixedTime.date(clock.date), #            visible: clock.minutes >= 0; text: Qt.formatTime(FixedTime.date(clock.date), ' \
  'shell/security/idle/IdleModel.js#var FAST_RETRY_MS = 5000;#var FAST_RETRY_MS = 5000; var WALL = SystemClock;' \
  'shell/security/idle/IdleModel.js#var FAST_RETRY_MS = 5000;#var FAST_RETRY_MS = 5000; var WALL = WallClock;' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 500\n    WallClock { id: wallProbe }' \
  'shell/security/lock/LockView.qml#        id: clock#        id: clock\n    }\n    WallClock {\n        id: probe' \
  'shell/security/idle/IdleModel.js#var FAST_EXIT_MS = 2000;#var FAST_EXIT_MS = 2000 + 0 * new Date().getTime();' \
  'shell/security/idle/IdleModel.js#var MAX_FAST_FAILURES = 5;#var MAX_FAST_FAILURES = 5 + 0 * performance.now();' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 3600000' \
  'shell/security/lock/Lock.qml#readonly property int verifyGraceMs: 500#readonly property int verifyGraceMs: 0' \
  'shell/security/lock/Lock.qml#                secureGrace.restart();#                secureGrace.restart(); secureGrace.repeat = true;' \
  'shell/security/lock/Lock.qml#        interval: ownershipProbe.verifyGraceMs#        interval: ownershipProbe.verifyGraceMs; repeat: true' \
  'shell/security/lock/Lock.qml#                secureGrace.restart();#                secureGrace.restart(); secureGrace.interval = 3600000;'; do
  IFS='#' read -r file from to <<<"$case_"
  cp "$root/$file" "$mut/$file"
  python3 -I - "$mut/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3]
s = open(p).read()
assert a in s, a
open(p, "w").write(s.replace(a, b.replace("\\n", "\n"), 1))
PY
  if python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1; then bad "mutation: removing '$from' in $file is not caught"; else pass "mutation: removing '$from' in $file is caught"; fi
  cp "$root/$file" "$mut/$file"
done

exit $fail
