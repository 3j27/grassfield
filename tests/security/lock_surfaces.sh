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
       re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused.*?heldClickAccepted\(Date\.now\(\)\s*-\s*root\.shownAt\).*?root\.userFocused\s*=\s*true", agent, re.S) is not None)
expect("polkit sheet: a request arriving or open while locked is held", re.search(r"heldByLock\s*=\s*active\s*&&\s*SessionState\.locked", agent) is not None
       and re.search(r"SessionState\.locked\s*&&\s*dialogModel\.active.*?heldByLock\s*=\s*true", agent, re.S) is not None)
expect("polkit sheet: a held request is not focused when it appears", re.search(r"if\s*\(shown\s*&&\s*!root\.heldByLock\)\s*dialog\.focusField\(\)", agent) is not None)
expect("polkit sheet: the typed text is dropped when the lock hides it", re.search(r"onShownChanged:.*?clearRequested\(\)", agent, re.S) is not None)

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
  shell/menubar/MenuBar.qml shell/desktop/HotCornerActions.js shell/security/polkit/AuthAgent.qml shell/desktop/IconsView.qml shell/desktop/DesktopWidgets.qml; do
  mkdir -p "$mut/$(dirname "$f")"
  cp "$root/$f" "$mut/$f"
done
python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1 && pass "mutation: the unchanged copy passes" || bad "mutation: the unchanged copy fails"
for case_ in 'shell/dock/Dock.qml#SessionState.refuses("dock keyboard")#false' \
  'shell/desktop/DesktopWidgets.qml#SessionState.refuses("widget menu")#false' \
  'shell/desktop/IconsView.qml#root.closeMenu("outside");#root.closeAbout("outside");' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows cycleApp")#false' \
  'shell/services/Popups.qml#SessionState.refuses("popup " + popupKind)#false' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && !SessionState.locked#dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#shown && (!root.heldByLock || root.userFocused)#shown' \
  'shell/security/polkit/AuthAgent.qml#if (shown && !root.heldByLock)#if (shown)'; do
  IFS='#' read -r file from to <<<"$case_"
  cp "$root/$file" "$mut/$file"
  python3 -I - "$mut/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a in s, a
open(p, "w").write(s.replace(a, b, 1))
PY
  if python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1; then bad "mutation: removing '$from' in $file is not caught"; else pass "mutation: removing '$from' in $file is caught"; fi
  cp "$root/$file" "$mut/$file"
done

exit $fail
