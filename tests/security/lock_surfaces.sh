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
#   polkit    a polkit sheet that arrives while locked is neither mapped nor given the keyboard until the unlock;
#   saver     SessionState.saverShown has one writer, the shell.qml Binding (ADR-0032).
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
first_decision("shell/search/Search.qml", "enterClipboard", R, lines=1)
first_decision("shell/launchpad/AppsController.qml", "show", R)
first_decision("shell/overview/Overview.qml", "show", R)
first_decision("shell/notifications/Notifications.qml", "openWidgetGallery", R)
first_decision("shell/dock/Dock.qml", "enterKeyboardMode", R)
toggle = function(read("shell/notifications/Notifications.qml"), "toggleCenter") or ""
opening = code(toggle).split("closeCenter();", 1)[-1]
expect("shell/notifications/Notifications.qml: toggleCenter() refuses before it opens", R in opening and opening.index(R) < opening.index("centerOpen = true"))
compositor = read("shell/platform/Compositor.qml")
windows = ipc(compositor, "windows")
for name in ("minimize", "tile", "arrange", "tilePopover", "nextOutput", "hide", "cycleApp"):
    first_decision("shell/platform/Compositor.qml", f"windows.{name}", R) if windows is None else first_decision("shell/platform/Compositor.qml", name, R, text=windows, lines=2)
# The plugin's minimize-request event (the titlebar button and, since GF-056 P8, a tagged window's own minimize button)
# moves nothing behind the lock either.
first_decision("shell/platform/Compositor.qml", "minimizeByAddress", R, text=compositor, lines=2)
# Tiling step 3 (integrator review of 4ead6fb): the plugin's hover event and Super+Ctrl+L open the popover only through here.
first_decision("shell/services/TilingHover.qml", "show", R)
# Tiling step 4a: the suggestions that follow a layout or an arrangement open only through here.
first_decision("shell/services/TilingSuggest.qml", "show", R)
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
route("shell/search/Search.qml", "search", "clipboard", r"root\.toggleClipboard\(\)")
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
expect("Search.toggleClipboard() opens only through show()", re.search(r"if\s*\(!open\)\s*show\(", code(function(search, "toggleClipboard") or "")) is not None
       and re.search(r"\bview\s*=", code(function(search, "toggleClipboard") or "")) is None)
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
arrive = code(function(agent, "arrive") or "")
expect("polkit sheet: shown only while active and unlocked", re.search(r"property bool shown:\s*dialogModel\.active\s*&&\s*!SessionState\.locked", agent) is not None)
# Check of c1ca44f (M1): `visible` and `takesKeys` read the base state only; through `shown` or `lingering` one went false for
# a moment when a request ended while the sink had the keys, and a hidden PanelWindow is destroyed and made again.
# Security counter-review of f9e24e1 (LOW-1): they read the agent's `requestOpen`, which only arrive writes (after the sink at
# an end), never the model's `active`: a request that ends unanswered under the user's typing never unmaps the window before
# the sink holds the keys.
notice_m = re.search(r"\bMaterial\s*\{\s*id:\s*endedNotice\b", agent)
notice = block_after(agent, notice_m.start()) if notice_m else ""
window_props = agent.replace(notice, "") if notice else agent
expect("polkit sheet: mapped only when a request is open, or while the sink lingers (never while locked), from the base state",
       re.search(r"\bvisible:\s*!SessionState\.locked\s*&&\s*\(root\.requestOpen\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None
       and re.search(r"property bool lingering:\s*root\.sinkingKeys\s*&&\s*!dialogModel\.active\s*&&\s*!SessionState\.locked\s*\n", agent) is not None)
expect("polkit sheet: takes the keyboard only when a request is open and not held, or for the sink, from the base state", re.search(r"keyboardFocus:\s*win\.takesKeys\s*\?\s*WlrKeyboardFocus\.Exclusive", agent) is not None
       and re.search(r"property bool takesKeys:\s*!SessionState\.locked\s*&&\s*\(\(root\.requestOpen\s*&&\s*\(!root\.heldByLock\s*\|\|\s*root\.userFocused\)\)\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None
       and notice != "" and not re.search(r"\b(?:visible|takesKeys):[^\n]*\b(?:shown|lingering|dialogModel\.active)\b", window_props))
expect("polkit sheet: requestOpen is written only by arrive, after the sink, false before the hold changes at an end and true after it at an arrival",
       len(re.findall(r"\brequestOpen\s*=(?!=)", agent)) == 2 and len(re.findall(r"\brequestOpen\s*=(?!=)", arrive)) == 2
       and re.search(r"^\s*property bool requestOpen:\s*false\s*$", agent, re.M) is not None
       and re.search(r"root\.sinkingKeys\s*=\s*typing;\s*if\s*\(!dialogModel\.active\)\s*root\.requestOpen\s*=\s*false;\s*root\.heldWhy\s*=[^;]*;\s*"
                     r"root\.heldByLock\s*=[^;]*;\s*root\.userFocused\s*=\s*false;\s*if\s*\(dialogModel\.active\)\s*root\.requestOpen\s*=\s*true;", arrive) is not None)
# Review of 1d2c856: a request held behind the lock takes the keyboard only after a click past the guard, never at once.
expect("polkit sheet: a held request takes the keyboard only after a click past the guard",
       re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused.*?if\s*\(!dialogModel\.heldClickAccepted\(\)\)\s*return;.*?root\.userFocused\s*=\s*true", agent, re.S) is not None
       and re.search(r"onShownChanged:\s*\{\s*if\s*\(shown\)\s*dialogModel\.noteShown\(\);", agent) is not None)
expect("polkit sheet: a request arriving while locked, or just after an unlock, is held",
       re.search(r"heldByLock\s*=\s*dialogModel\.active\s*&&\s*\(follows\s*\|\|\s*typing\s*\|\|\s*dialogModel\.arrivesHeld\(SessionState\.locked\s*\|\|\s*SessionState\.saverShown\)\);", agent) is not None
       and re.search(r"const queued\s*=\s*follows\s*\|\|\s*typing\s*\|\|\s*\(dialogModel\.active\s*&&\s*dialogModel\.followsAnother\(\)\);", arrive) is not None
       and re.search(r"if\s*\(!SessionState\.locked\)\s*\{\s*dialogModel\.noteUnlock\(\);", agent) is not None)
# Review of 6e24d36: the unlock hold and the click guard are timed by Timers (monotonic), never by the wall clock; the
# agent reads Date.now() only for the arrival time the notice shows.
model = code(read("shell/security/polkit/AuthDialogModel.qml"))
bodies = {n: code(function(model, n) or "") for n in ("noteUnlock", "noteShown", "heldClickAccepted", "arrivesHeld", "noteUncovered", "noteEnded", "followsAnother")}
expect("polkit holds: timed by Timers, never by the wall clock",
       len(re.findall(r"\bDate\b", agent)) == 1 and re.search(r"requestStartedAt\s*=\s*dialogModel\.active\s*\?\s*new Date\(\)\s*:\s*null", agent) is not None
       and not any(re.search(r"\bDate\b", b) for b in bodies.values())
       and re.search(r"property Timer unlockHold:\s*Timer\s*\{\s*interval:\s*root\.heldAfterUnlockMs\s*\}", model) is not None
       and re.search(r"property Timer clickGuard:\s*Timer\s*\{\s*interval:\s*root\.heldGuardMs\s*\}", model) is not None
       and re.search(r"^\s*unlockHold\.restart\(\);\s*$", bodies["noteUnlock"], re.M) is not None
       and re.search(r"priv\.shown\s*=\s*true;\s*clickGuard\.restart\(\);", bodies["noteShown"]) is not None
       and re.search(r"^\s*return\s+priv\.shown\s*&&\s*!clickGuard\.running;\s*$", bodies["heldClickAccepted"], re.M) is not None
       and re.search(r"^\s*return\s+locked\s*\|\|\s*unlockHold\.running\s*\|\|\s*afterRequest\.running;\s*$", bodies["arrivesHeld"], re.M) is not None
       and re.search(r"^\s*clickGuard\.restart\(\);\s*$", bodies["noteUncovered"], re.M) is not None
       and re.search(r"property Timer afterRequest:\s*Timer\s*\{\s*interval:\s*root\.heldAfterUnlockMs\s*\}", model) is not None
       and re.search(r"^\s*afterRequest\.restart\(\);\s*$", bodies["noteEnded"], re.M) is not None
       and re.search(r"^\s*return\s+afterRequest\.running;\s*$", bodies["followsAnother"], re.M) is not None)
# Re-check of b5d7657 (MEDIUM-3): each hold Timer is used only where it is meant to be, and never from the agent.
expect("polkit holds: each Timer only in its own functions (clickGuard 4, unlockHold 3, afterRequest 4 uses), none in the agent",
       len(re.findall(r"\bclickGuard\b", model)) == 4 and len(re.findall(r"\bunlockHold\b", model)) == 3
       and len(re.findall(r"\bafterRequest\b", model)) == 4
       and not re.search(r"\b(clickGuard|unlockHold|afterRequest)\b", agent))
# ADR-0032 (owner decision 2026-10-26): the screen saver holds a request as the lock does, its waking click answers nothing,
# and the click guard starts over when it ends.
saver_hold = code(function(agent, "onSaverShownChanged") or "")
expect("polkit sheet: the screen saver takes the sink's keys, then a request open when it comes up is held, its field emptied (nothing but the lock and no request return first)",
       re.match(r"\s*if\s*\(SessionState\.saverShown\)\s*root\.sinkingKeys\s*=\s*false;\s*if\s*\(!dialogModel\.active\s*\|\|\s*SessionState\.locked\)\s*return;\s*if\s*\(SessionState\.saverShown\)\s*\{", saver_hold) is not None
       and re.search(r"if\s*\(SessionState\.saverShown\)\s*\{.*?root\.heldByLock\s*=\s*true;\s*root\.userFocused\s*=\s*false;\s*dialogModel\.clearRequested\(\);", saver_hold, re.S) is not None)
# Review of f513b3b (MEDIUM-1): the link that carries the saver's state, and who may give the keyboard or set the hold.
expect("shell.qml binds SessionState.saverShown to the screen saver's shown",
       re.search(r"Binding\s*\{\s*target:\s*SessionState\s*property:\s*\"saverShown\"\s*value:\s*saver\.shown\s*\}", shell) is not None
       and re.search(r"\bSaver\s*\{\s*id:\s*saver\b", shell) is not None)
# ADR-0032: that Binding is the only writer of SessionState.saverShown in the shell, the apps and Grassfield.Ui: no
# assignment, no other Binding, PropertyChanges or object property, no other quoted name (setProperty and the like). A
# wrong saverShown holds every polkit request (true) or lets the sheet take the keyboard over the saver (false).
def saver_writes():
    import os
    found = []
    for top in ("shell", "apps", "ui"):
        for dirpath, dirnames, filenames in os.walk(f"{root}/{top}"):
            dirnames[:] = [d for d in dirnames if d not in (".dev", "build")]
            for name in filenames:
                if not name.endswith((".qml", ".js")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = code(f.read())
                for m in re.finditer(r"\bsaverShown\s*=(?!=)|[\"']saverShown[\"']|\bsaverShown\s*:", text):
                    line = text[text.rfind("\n", 0, m.start()) + 1:text.find("\n", m.start()) if text.find("\n", m.start()) >= 0 else len(text)].strip()
                    if rel == "shell/services/SessionState.qml" and re.fullmatch(r"property bool saverShown:\s*false", line):
                        continue
                    found.append(f"{rel}: {line}")
    return found
writes = saver_writes()
expect("SessionState.saverShown has one writer, the shell.qml Binding (" + "; ".join(writes) + ")",
       writes == ['shell/shell.qml: property: "saverShown"'])
expect("polkit sheet: only a click past the guard gives the keyboard (one userFocused = true), and an arrival, a lock and the saver take it back (three userFocused = false)",
       len(re.findall(r"userFocused\s*=\s*true", agent)) == 1 and len(re.findall(r"userFocused\s*=\s*false", agent)) == 3)
# Re-check of b5d7657 (MEDIUM-3): the sheet, then the held click's guard over it, then the saver's swallowing area on top.
order = [m.start() if m else -1 for m in (re.search(r"\bLoader\s*\{\s*id:\s*holder", agent),
                                          re.search(r"enabled:\s*root\.heldByLock\s*&&\s*!root\.userFocused", agent),
                                          re.search(r"enabled:\s*SessionState\.saverShown", agent))]
expect("polkit sheet: the sheet, its held-click guard above it, the saver's swallowing area on top", -1 not in order and order == sorted(order))
# Re-check of b5d7657 (MEDIUM-2): a request that replaces the one being typed into keeps the keyboard on a sink, never
# handing the rest of a password to the window underneath, until a click past the guard.
# Check of 38dbfe8: `typing` is read before arrive changes what takesKeys reads (its LOW-2 M1), the sink keeps the keys when
# the request ends (MEDIUM-B) and takes back any focus while it has them (MEDIUM-A), and Esc cancels a held request (LOW-1).
expect("polkit sheet: a request replacing the one being typed into, ending unanswered while the window has the keys, or arriving or ending while the sink has them, keeps them on the sink (read first)",
       re.match(r"\s*const typing\s*=\s*\(follows\s*&&\s*win\.takesKeys\)\s*\|\|\s*root\.sinkingKeys\s*\|\|\s*\(!dialogModel\.active\s*&&\s*win\.takesKeys\s*&&\s*!dialogModel\.answered\);\s*\n", arrive) is not None
       and re.search(r"root\.sinkingKeys\s*=\s*typing;", arrive) is not None
       and re.search(r"onSinkingKeysChanged:\s*if\s*\(sinkingKeys\)\s*keySink\.forceActiveFocus\(\)", agent) is not None
       and re.search(r"Item\s*\{\s*id:\s*keySink\s*Keys\.onPressed:\s*event\s*=>\s*\{\s*event\.accepted\s*=\s*true;\s*if\s*\(root\.lingering\)\s*sinkIdle\.restart\(\);\s*"
                     r"else if\s*\(event\.key\s*===\s*Qt\.Key_Escape\)\s*dialogModel\.cancel\(\);\s*\}\s*Keys\.onReleased:\s*event\s*=>\s*event\.accepted\s*=\s*true\s*\}", agent) is not None
       # Check of c1ca44f (M2): while the sink has the keys the sheet's input is disabled and any focus it gets goes back to the
       # sink, whether or not its window has the keyboard; its focusField does nothing while the input is disabled.
       and re.search(r"inputEnabled:\s*!root\.sinkingKeys\s*onActiveFocusChanged:\s*if\s*\(activeFocus\s*&&\s*root\.sinkingKeys\)\s*keySink\.forceActiveFocus\(\)", agent) is not None
       and re.search(r"root\.userFocused\s*=\s*true;\s*root\.sinkingKeys\s*=\s*false;", agent) is not None)
expect("polkit sheet: the sink lets go only on a click past the guard, the lock, the screen saver, or the linger's click or timers (six sinkingKeys = false, one = typing)",
       len(re.findall(r"\bsinkingKeys\s*=\s*false\b", agent)) == 6 and len(re.findall(r"\bsinkingKeys\s*=(?!=)", agent)) == 7
       and re.search(r"function onLockedChanged\(\):\s*void\s*\{\s*if\s*\(!SessionState\.locked\)\s*\{\s*dialogModel\.noteUnlock\(\);\s*return;\s*\}\s*root\.sinkingKeys\s*=\s*false;", agent) is not None)
expect("polkit sheet: the linger ends after heldAfterUnlockMs without a key or sinkLingerMaxMs, both started when it starts, neither touching a request's sink",
       len(re.findall(r"Timer\s*\{\s*id:\s*sink(?:Idle|Cap)\s*interval:\s*dialogModel\.(?:heldAfterUnlockMs|sinkLingerMaxMs)\s*onTriggered:\s*if\s*\(root\.lingering\)\s*root\.sinkingKeys\s*=\s*false\s*\}", agent)) == 2
       and re.search(r"id:\s*sinkIdle\s*interval:\s*dialogModel\.heldAfterUnlockMs\b", agent) is not None
       and re.search(r"id:\s*sinkCap\s*interval:\s*dialogModel\.sinkLingerMaxMs\b", agent) is not None
       and re.search(r"if\s*\(typing\s*&&\s*!dialogModel\.active\s*&&\s*!SessionState\.locked\)\s*\{\s*sinkIdle\.restart\(\);\s*sinkCap\.restart\(\);\s*\}", arrive) is not None
       and "lingering" not in arrive
       and re.search(r"readonly property int sinkLingerMaxMs:\s*3000\s*\n", model) is not None)
# Security counter-review of f9e24e1 (LOW-1): `answered` is set by the user's answer only (submit, cancel), cleared when polkit
# asks again (a failure, a new prompt) and for a new request, never when a request ends (the agent reads it then); the
# agent never writes it.
expect("polkit sheet: `answered` is set by submit and cancel only, cleared on a failure, a new prompt or a new request, never at the end",
       re.search(r"readonly property bool answered:\s*priv\.answered\s*\n", model) is not None
       and len(re.findall(r"\banswered\s*=(?!=)", model)) == 5
       and len(re.findall(r"\bpriv\.answered\s*=\s*true;", model)) == 2 and len(re.findall(r"\bpriv\.answered\s*=\s*false;", model)) == 3
       and re.search(r"priv\.submitted\s*=\s*true;\s*priv\.answered\s*=\s*true;", code(function(model, "submit") or "")) is not None
       and re.search(r"priv\.answered\s*=\s*true;", code(function(model, "cancel") or "")) is not None
       and re.search(r"onFlowChanged:\s*\{\s*priv\.submitted\s*=\s*false;\s*priv\.error\s*=\s*\"\";\s*if\s*\(flow\)\s*priv\.answered\s*=\s*false;\s*clearRequested\(\);\s*\}", model) is not None
       and re.search(r"if\s*\(root\.flow\s*&&\s*root\.flow\.isResponseRequired\)\s*\{\s*root\.priv\.submitted\s*=\s*false;\s*root\.priv\.answered\s*=\s*false;\s*\}", model) is not None
       and re.search(r"function onAuthenticationFailed\(\):\s*void\s*\{\s*root\.priv\.submitted\s*=\s*false;\s*root\.priv\.answered\s*=\s*false;", model) is not None
       and not re.search(r"\banswered\s*=(?!=)", agent))
# LOW-3: the linger is shown by a card of fixed text where the sheet was, only while the sink lingers; it takes no input and no
# focus (a press goes through to the backdrop, which ends the linger) and shows nothing of the requester's.
expect("polkit sheet: the ended notice shows only while the sink lingers, fixed text, no input, no focus, nothing of the request",
       re.match(r"\s*id:\s*endedNotice\s*objectName:\s*\"polkitEndedNotice\"\s*visible:\s*root\.lingering\s*\n", notice) is not None
       and not re.search(r"MouseArea|TapHandler|Handler\s*\{|\bfocus\s*:|activeFocusOnTab|Keys\.|TextInput|TextEdit|Button|forceActiveFocus|dialogModel|model\.|\bflow\b", notice)
       and re.findall(r"\btext:\s*([^\n]*)", notice) == ['qsTr("Request cancelled")', 'qsTr("What you type is ignored for a moment.")']
       and re.findall(r"textFormat:\s*(\S+)", notice) == ["Text.PlainText", "Text.PlainText"])
dialog_src = code(read("shell/security/polkit/AuthDialog.qml"))
backdrop = re.search(r"MouseArea\s*\{\s*anchors\.fill:\s*parent\s*onPressed:\s*\{\s*if\s*\(root\.lingering\)\s*\{\s*root\.sinkingKeys\s*=\s*false;\s*return;\s*\}\s*"
                     r"const dialog\s*=\s*holder\.item as AuthDialog;\s*if\s*\(dialog\s*&&\s*win\.takesKeys\s*&&\s*!root\.sinkingKeys\)\s*dialog\.focusField\(\);\s*\}\s*\}", agent)
expect("polkit sheet: the field is focused only where it may be (the agent: when shown unheld, a backdrop click with the keyboard and no sink, the click past the guard; the sheet: when it loads and after a failure)",
       backdrop is not None and len(re.findall(r"\.focusField\(\)", agent)) == 3
       and len(re.findall(r"\bfocusField\(\)", dialog_src)) == 3 and re.search(r"Component\.onCompleted:\s*focusField\(\)", dialog_src) is not None
       and re.search(r"function focusField\(\):\s*void\s*\{\s*if\s*\(root\.inputEnabled\)\s*field\.forceActiveFocus\(\);\s*\}", dialog_src) is not None
       and len(re.findall(r"enabled:\s*root\.inputEnabled\b", dialog_src)) == 3 and re.search(r"id:\s*identityList\s*enabled:\s*root\.inputEnabled\b", dialog_src) is not None and re.search(r"property bool inputEnabled:\s*true\s*\n", dialog_src) is not None
       and re.search(r"function onFailed\(\):\s*void\s*\{\s*shakeAnimation\.restart\(\);\s*root\.focusField\(\);\s*\}", dialog_src) is not None)
expect("polkit sheet: a request that comes right after another one ended is held (noteEnded when none is left)",
       re.search(r"if\s*\(!dialogModel\.active\)\s*dialogModel\.noteEnded\(\);", arrive) is not None)
expect("polkit sheet: the hold is set only on an arrival, a lock and the screen saver",
       len(re.findall(r"\bheldByLock\s*=(?!=)", agent)) == 3)
# Review of f513b3b (MEDIUM-2): a queued request that follows another in the same sheet is a new arrival, held; whether a
# request is in the sheet is a flag, never a flow read back (it reads null once destroyed; review of 9ad4307..b38618f).
flow_changed = code(block_after(agent, re.search(r"onFlowChanged:", agent).end()) if re.search(r"onFlowChanged:", agent) else "")
expect("polkit sheet: a queued request that follows another is held, emptied, its guard started over",
       re.search(r"const follows\s*=\s*root\.flowShown\s*&&\s*flow\s*!==\s*null\s*&&\s*flow\s*!==\s*root\.shownFlow;\s*root\.flowShown\s*=\s*flow\s*!==\s*null;\s*root\.shownFlow\s*=\s*flow;\s*if\s*\(follows\)\s*root\.arrive\(true\);", flow_changed) is not None
       and re.search(r"^\s*property bool flowShown:\s*false\s*$", agent, re.M) is not None
       and re.search(r"onActiveChanged:\s*root\.arrive\(false\)", agent) is not None
       and re.search(r"if\s*\(follows\)\s*\{\s*dialogModel\.clearRequested\(\);\s*dialogModel\.noteShown\(\);\s*\}", arrive) is not None)
expect("polkit sheet: the click guard starts over when the screen saver ends",
       re.search(r"else if\s*\(root\.heldByLock\)\s*\{\s*dialogModel\.noteUncovered\(\);", saver_hold) is not None)
expect("polkit sheet: a press goes nowhere while the screen saver shows",
       re.search(r"MouseArea\s*\{\s*anchors\.fill:\s*parent\s*enabled:\s*SessionState\.saverShown\s*acceptedButtons:\s*Qt\.AllButtons\s*onPressed:\s*mouse\s*=>\s*mouse\.accepted\s*=\s*true\s*onWheel:\s*wheel\s*=>\s*wheel\.accepted\s*=\s*true\s*\}", agent) is not None)
expect("polkit sheet: a request open when the lock engages is held",
       re.search(r"root\.sinkingKeys\s*=\s*false;\s*if\s*\(dialogModel\.active\)\s*\{\s*root\.heldByLock\s*=\s*true;\s*root\.heldWhy\s*=\s*\"locked\";\s*root\.userFocused\s*=\s*false;\s*\}", agent) is not None)
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
# Review of the lock's monitor queries (Quickshell 0.3.1 IPC, read in its source): Hyprland.refreshMonitors() from QML never
# creates a monitor object, and one sent before Hyprland answered Quickshell's own first query (`j/status`) makes Quickshell
# drop its start-up query: Hyprland.monitors then stays empty until a monitor event, and the stranded check, the ownership
# check and verify() never get an answer (the re-lock after a foreign release was inert, the sleep delay ran out unconfirmed).
#   queries  the shell (shell/ and ui/) has two Hyprland.refreshMonitors() calls: Lock.qml requestMonitors() behind the guard
#            on the live model's count (Machine.monitorQueryAllowed), through which every lock query goes, and Displays.qml's
#            Hyprland event handler (opus review of 94ab527, MINOR-2: the bug first came from a Displays start-up call);
#   watcher  monitorAnswers follows the live model, its delegates hand every answer to checkOwnership, and a monitor added
#            while holding asks for a fresh answer at once (monitorsAdded);
#   stranded only Hyprland's answers decide; an empty model is "unknown" (LockMachine, unit-tested): no takeover and no stop
#            as "nothing stranded" until the ticks run out; a check still undecided (running, or out of ticks because
#            Quickshell's first answer came later) runs again when monitors appear, before this shell locked (MINOR-1);
#   log      the empty model is logged once: the flag is read before the warning, set after it, cleared only in monitorsAdded.
refresh_hits = []
for top in ("shell", "ui"):
    for base, _, files in os.walk(f"{root}/{top}"):
        for name in sorted(files):
            if name.endswith((".qml", ".js")):
                rel = os.path.relpath(os.path.join(base, name), root)
                refresh_hits += [rel for _ in re.finditer(r"\brefreshMonitors\s*\(", nocomments(read(rel)))]
request = code(function(lock, "requestMonitors") or "")
expect("lock monitor queries: one Hyprland.refreshMonitors() in shell/security, in requestMonitors() behind the empty-model guard (" + ", ".join(refresh_hits) + ")",
       refresh_hits.count("shell/security/lock/Lock.qml") == 1
       and not any(h.startswith("shell/security/") and h != "shell/security/lock/Lock.qml" for h in refresh_hits)
       and re.fullmatch(r"\s*if\s*\(!Machine\.monitorQueryAllowed\(Hyprland\.monitors\.values\.length\)\)\s*\{\s*if\s*\(!emptyModelLogged\)\s*console\.warn\(\"[^\"]*\"\);\s*emptyModelLogged\s*=\s*true;\s*return false;\s*\}\s*Hyprland\.refreshMonitors\(\);\s*return true;\s*", request) is not None)
# The only other call: Displays.qml's handler of Hyprland events (monitors added or removed, configreloaded). Safe: Hyprland
# events reach QML only once Hyprland answered Quickshell's first query (Quickshell connects its event socket in that answer's
# callback, right before its own refreshMonitors(true)), so this call can never come before Quickshell's start-up query; on
# configreloaded Quickshell's own refreshMonitors(true) is already sent (this one is dropped as a duplicate), and a monitor
# added later is created by Quickshell's monitoraddedv2 handler itself, not by a monitors answer.
displays = nocomments(read("shell/platform/Displays.qml"))
handler_m = re.search(r"Connections\s*\{\s*target:\s*Hyprland\s+function onRawEvent\(event:\s*HyprlandEvent\):\s*void\s*\{", displays)
handler = block_after(displays, handler_m.start()) if handler_m else ""
expect("monitor queries outside the lock: only Displays.qml's Hyprland event handler (" + ", ".join(refresh_hits) + ")",
       sorted(refresh_hits) == ["shell/platform/Displays.qml", "shell/security/lock/Lock.qml"]
       and len(re.findall(r"\brefreshMonitors\s*\(", handler)) == 1
       and re.search(r"if\s*\(event\.name\s*===\s*\"monitoradded\"[^{]*\"configreloaded\"\)\s*\{\s*Hyprland\.refreshMonitors\(\);", handler) is not None)
monitors_added = code(function(lock, "monitorsAdded") or "")
expect("lock monitor queries: verify(), the ownership confirmation, the stranded check, ownershipProbe and monitorsAdded go through requestMonitors()",
       re.search(r"verified\s*=\s*false;\s*requestMonitors\(\);\s*$", code(function(lock, "verify") or "")) is not None
       and re.search(r"if\s*\(action\s*===\s*\"confirm\"\)\s*requestMonitors\(\);\s*else if", code(function(lock, "checkOwnership") or "")) is not None
       and re.search(r"\}\s*else\s*\{\s*requestMonitors\(\);\s*\}\s*$", code(function(lock, "checkStranded") or "")) is not None
       and re.search(r"Timer\s*\{\s*id:\s*ownershipProbe\b[^}]*?onTriggered:\s*root\.requestMonitors\(\)\s*\}", lock, re.S) is not None
       and re.search(r"if\s*\(holding\)\s*requestMonitors\(\);", monitors_added) is not None)
expect("lock ownership watcher: follows the live monitor model, every answer reaches checkOwnership, an added monitor calls monitorsAdded",
       re.search(r"Instantiator\s*\{\s*id:\s*monitorAnswers\s+active:\s*root\.hyprland\s+model:\s*Hyprland\.monitors\s+onObjectAdded:\s*Qt\.callLater\(root\.monitorsAdded\)\s+"
                 r"delegate:\s*Connections\s*\{\s*required property HyprlandMonitor modelData\s+target:\s*modelData\s+"
                 r"function onLastIpcObjectChanged\(\):\s*void\s*\{\s*Qt\.callLater\(root\.checkOwnership\);\s*\}\s*\}\s*\}", lock) is not None)
stranded = code(function(lock, "checkStranded") or "")
expect("lock stranded check: only Hyprland's answers decide; unknown (an empty model) neither takes over nor stops before the ticks run out",
       re.search(r"if\s*\(currentlyLocked\(\)\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*return;\s*\}\s*"
                 r"const monitors\s*=\s*Hyprland\.monitors\.values\.map\(m\s*=>\s*m\.lastIpcObject\);\s*const state\s*=\s*Machine\.compositorLockState\(monitors\);\s*"
                 r"if\s*\(state\s*===\s*\"locked\"\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;[^}]*\}\s*"
                 r"else if\s*\(state\s*===\s*\"unlocked\"\)\s*\{\s*strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*\}\s*"
                 r"else if\s*\(--strandedProbe\.remaining\s*<=\s*0\)\s*\{", stranded) is not None)
unknown_m = re.search(r"else if\s*\(--strandedProbe\.remaining\s*<=\s*0\)\s*\{", stranded)
unknown_branch = block_after(stranded, unknown_m.start()) if unknown_m else "strandedUndecided"
expect("lock stranded check: undecided from its start until Hyprland answers locked or unlocked (or this shell locks); "
       "monitors appearing before this shell locked run it again (only ever a takeover)",
       re.search(r"^\s*property bool strandedUndecided:\s*false\s*$", lock, re.M) is not None
       and re.search(r"if\s*\(!controller\.locked\s*&&\s*root\.hyprland\)\s*\{\s*strandedUndecided\s*=\s*true;\s*strandedProbe\.start\(\);\s*\}", lock) is not None
       and len(re.findall(r"\bstrandedUndecided\s*=\s*true;", lock)) == 1
       and len(re.findall(r"\bstrandedUndecided\s*=\s*false;", lock)) == 4
       and re.search(r"strandedProbe\.stop\(\);\s*strandedUndecided\s*=\s*false;\s*console\.info\(\"grassfield-lock: lock requested \(\"", code(function(lock, "lock") or "")) is not None
       and len(re.findall(r"\bstrandedUndecided\s*=\s*false;", stranded)) == 3
       and "strandedUndecided" not in unknown_branch
       and re.search(r"if\s*\(holding\)\s*requestMonitors\(\);\s*else if\s*\(strandedUndecided\)\s*checkStranded\(\);\s*$", monitors_added) is not None)
expect("lock monitor queries: the empty model is logged once, the flag cleared only when a monitor appears",
       re.search(r"^\s*property bool emptyModelLogged:\s*false\s*$", lock, re.M) is not None
       and len(re.findall(r"\bemptyModelLogged\s*=\s*true;", lock)) == 1
       and len(re.findall(r"\bemptyModelLogged\s*=\s*false;", lock)) == 1
       and re.search(r"^\s*if\s*\(emptyModelLogged\)\s*\{\s*emptyModelLogged\s*=\s*false;", monitors_added) is not None)
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
  shell/desktop/IconsView.qml shell/desktop/DesktopWidgets.qml shell/platform/Displays.qml shell/services/TilingHover.qml \
  shell/services/TilingSuggest.qml; do
  mkdir -p "$mut/$(dirname "$f")"
  cp "$root/$f" "$mut/$f"
done
cp -a "$root/shell/security" "$mut/shell/" # the wall-clock scan reads every file of shell/security
python3 -I "$tmp/check.py" "$mut" >/dev/null 2>&1 && pass "mutation: the unchanged copy passes" || bad "mutation: the unchanged copy fails"
for case_ in 'shell/dock/Dock.qml#SessionState.refuses("dock keyboard")#false' \
  'shell/desktop/DesktopWidgets.qml#SessionState.refuses("widget menu")#false' \
  'shell/desktop/IconsView.qml#root.closeMenu("outside");#root.closeAbout("outside");' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows cycleApp")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows arrange")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows tilePopover")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows nextOutput")#false' \
  'shell/services/TilingHover.qml#SessionState.refuses("tiling popover")#false' \
  'shell/services/TilingSuggest.qml#SessionState.refuses("tiling suggestions")#false' \
  'shell/platform/Compositor.qml#SessionState.refuses("windows minimize request")#false' \
  'shell/services/Popups.qml#SessionState.refuses("popup " + popupKind)#false' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && !SessionState.locked#dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#(root.requestOpen || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = false;' \
  'shell/security/polkit/AuthAgent.qml#                event.accepted = true;\n                if (root.lingering)#                event.accepted = false;\n                if (root.lingering)' \
  'shell/security/polkit/AuthAgent.qml#        root.userFocused = false;\n        if (dialogModel.active)\n            root.requestOpen = true;#        if (dialogModel.active)\n            root.requestOpen = true;' \
  'shell/security/polkit/AuthAgent.qml#            dialogModel.noteEnded();#            ;' \
  'shell/security/polkit/AuthDialogModel.qml#return locked || unlockHold.running || afterRequest.running;#return locked || unlockHold.running;' \
  'shell/security/polkit/AuthAgent.qml#if (shown && !root.heldByLock)#if (shown)' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.arrivesHeld(SessionState.locked || SessionState.saverShown)#SessionState.locked || SessionState.saverShown' \
  'shell/security/polkit/AuthAgent.qml#arrivesHeld(SessionState.locked || SessionState.saverShown)#arrivesHeld(SessionState.locked)' \
  'shell/security/polkit/AuthAgent.qml#                root.heldByLock = true;\n                root.userFocused = false;\n                dialogModel.clearRequested();#                root.userFocused = false;' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUncovered();#;' \
  'shell/security/polkit/AuthAgent.qml#enabled: SessionState.saverShown#enabled: false' \
  'shell/security/polkit/AuthAgent.qml#acceptedButtons: Qt.AllButtons#acceptedButtons: Qt.LeftButton' \
  'shell/shell.qml#        property: "saverShown"\n        value: saver.shown#        property: "saverShown"\n        value: false' \
  'shell/services/SessionState.qml#    property bool saverShown: false#    property bool saverShown: false\n    function hideSaver(): void {\n        saverShown = false;\n    }' \
  'shell/shell.qml#        property: "saverShown"\n        value: saver.shown\n    }#        property: "saverShown"\n        value: saver.shown\n    }\n    Binding {\n        target: SessionState\n        property: "saverShown"\n        value: false\n        when: false\n    }' \
  'shell/security/polkit/AuthAgent.qml#if (!dialogModel.active || SessionState.locked)#if (!dialogModel.active || SessionState.locked || !SessionState.saverShown)' \
  'shell/security/polkit/AuthAgent.qml#        root.userFocused = false;\n        if (dialogModel.active)\n            root.requestOpen = true;#        root.userFocused = true;\n        if (dialogModel.active)\n            root.requestOpen = true;' \
  'shell/security/polkit/AuthAgent.qml#const follows = root.flowShown#const follows = false && root.flowShown' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.active && (follows || #dialogModel.active && (' \
  'shell/security/polkit/AuthAgent.qml#            dialogModel.clearRequested();\n            dialogModel.noteShown();#            dialogModel.clearRequested();' \
  'shell/security/polkit/AuthDialogModel.qml#        clickGuard.restart();\n    }\n\n    // The request in the sheet ended#    }\n\n    // The request in the sheet ended' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteUnlock();#root.unlockedAt = Date.now();' \
  'shell/security/polkit/AuthAgent.qml#dialogModel.noteShown();#root.shownAt = Date.now();' \
  'shell/security/polkit/AuthDialogModel.qml#return locked || unlockHold.running || afterRequest.running;#return locked || Date.now() - priv.unlockedAt < heldAfterUnlockMs;' \
  'shell/security/polkit/AuthDialogModel.qml#return priv.shown && !clickGuard.running;#return !clickGuard.running;' \
  'shell/security/polkit/AuthAgent.qml#active ? new Date() : null#active ? Date.now() : 0' \
  'shell/security/polkit/AuthAgent.qml#onActiveFocusChanged: if (activeFocus && root.sinkingKeys)#onActiveFocusChanged: if (false)' \
  'shell/security/polkit/AuthAgent.qml#visible: !SessionState.locked && (root.requestOpen || root.sinkingKeys)#visible: shown || root.lingering' \
  'shell/security/polkit/AuthAgent.qml#takesKeys: !SessionState.locked && ((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#takesKeys: (shown && (!root.heldByLock || root.userFocused || root.sinkingKeys)) || root.lingering' \
  'shell/security/polkit/AuthAgent.qml#inputEnabled: !root.sinkingKeys#inputEnabled: true' \
  'shell/security/polkit/AuthAgent.qml#if (typing && !dialogModel.active && !SessionState.locked) {#if (root.lingering) {' \
  'shell/security/polkit/AuthDialog.qml#        if (root.inputEnabled)\n            field.forceActiveFocus();#        field.forceActiveFocus();' \
  'shell/security/polkit/AuthDialog.qml#                id: field\n                enabled: root.inputEnabled#                id: field' \
  'shell/security/polkit/AuthDialog.qml#            id: identityList\n            enabled: root.inputEnabled#            id: identityList' \
  'shell/security/polkit/AuthDialog.qml#                // No focus while AuthAgent keeps the keys on its sink (as the identity rows).\n                enabled: root.inputEnabled#                // No focus while AuthAgent keeps the keys on its sink (as the identity rows).' \
  'shell/security/polkit/AuthAgent.qml#        const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);\n        const queued = follows || typing || (dialogModel.active && dialogModel.followsAnother());#        let typing = false;\n        const queued = follows || typing || (dialogModel.active && dialogModel.followsAnother());\n        typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || (!dialogModel.active && win.takesKeys && !dialogModel.answered);' \
  'shell/security/polkit/AuthAgent.qml#visible: !SessionState.locked && (root.requestOpen || root.sinkingKeys)#visible: !SessionState.locked && root.requestOpen' \
  'shell/security/polkit/AuthAgent.qml#root.sinkingKeys && !dialogModel.active && !SessionState.locked#root.sinkingKeys && !dialogModel.active' \
  'shell/security/polkit/AuthAgent.qml#                return;\n            }\n            root.sinkingKeys = false;#                return;\n            }' \
  'shell/security/polkit/AuthAgent.qml#            if (SessionState.saverShown)\n                root.sinkingKeys = false;\n#' \
  'shell/security/polkit/AuthAgent.qml#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (root.lingering)#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (true)' \
  'shell/security/polkit/AuthAgent.qml#        if (typing && !dialogModel.active && !SessionState.locked) {\n            sinkIdle.restart();\n            sinkCap.restart();\n        }\n#' \
  'shell/security/polkit/AuthAgent.qml#if (dialog && win.takesKeys && !root.sinkingKeys)#if (dialog)' \
  'shell/security/polkit/AuthAgent.qml#(follows || typing || dialogModel.arrivesHeld(#(follows || dialogModel.arrivesHeld(' \
  'shell/security/polkit/AuthDialog.qml#            field.clear();\n#            field.clear();\n            root.focusField();\n' \
  'shell/security/polkit/AuthAgent.qml#                else if (event.key === Qt.Key_Escape)\n                    dialogModel.cancel();#                else if (event.key === Qt.Key_Escape)\n                    ;' \
  'shell/security/polkit/AuthDialogModel.qml#readonly property int sinkLingerMaxMs: 3000#readonly property int sinkLingerMaxMs: 30000' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys;' \
  'shell/security/polkit/AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys);' \
  'shell/security/polkit/AuthAgent.qml#visible: !SessionState.locked && (root.requestOpen || root.sinkingKeys)#visible: !SessionState.locked && (dialogModel.active || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#((dialogModel.active && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)' \
  'shell/security/polkit/AuthAgent.qml#        root.sinkingKeys = typing;\n        if (!dialogModel.active)\n            root.requestOpen = false;#        if (!dialogModel.active)\n            root.requestOpen = false;\n        root.sinkingKeys = typing;' \
  'shell/security/polkit/AuthAgent.qml#            root.sinkingKeys = false;\n            if (dialogModel.active) {#            root.sinkingKeys = false;\n            root.requestOpen = false;\n            if (dialogModel.active) {' \
  'shell/security/polkit/AuthDialogModel.qml#        if (flow)\n            priv.answered = false;#        priv.answered = false;' \
  'shell/security/polkit/AuthDialogModel.qml#        priv.submitted = false;\n        priv.answered = true;#        priv.submitted = false;' \
  'shell/security/polkit/AuthDialogModel.qml#            root.priv.submitted = false;\n            root.priv.answered = false;\n            root.priv.error#            root.priv.submitted = false;\n            root.priv.error' \
  'shell/security/polkit/AuthAgent.qml#            visible: root.lingering#            visible: root.sinkingKeys' \
  'shell/security/polkit/AuthAgent.qml#            radius: Tokens.radiusDialog\n\n            Column {#            radius: Tokens.radiusDialog\n            MouseArea { anchors.fill: parent }\n\n            Column {' \
  'shell/security/polkit/AuthAgent.qml#                    text: qsTr("Request cancelled")#                    text: dialogModel.message' \
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
  'shell/security/lock/Lock.qml#                secureGrace.restart();#                secureGrace.restart(); secureGrace.interval = 3600000;' \
  'shell/security/lock/Lock.qml#if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {#if (false) {' \
  'shell/security/lock/Lock.qml#if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {#if (!Machine.monitorQueryAllowed(1)) {' \
  'shell/security/lock/Lock.qml#        onTriggered: root.requestMonitors()#        onTriggered: Hyprland.refreshMonitors()' \
  'shell/security/lock/Lock.qml#        verified = false;\n        requestMonitors();#        verified = false;\n        Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#        if (action === "confirm")\n            requestMonitors();#        if (action === "confirm")\n            Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#            requestMonitors(); // none while#            Hyprland.refreshMonitors(); // none while' \
  'shell/security/lock/Lock.qml#        restore(false, "start");#        restore(false, "start");\n        Hyprland.refreshMonitors();' \
  'shell/security/lock/Lock.qml#        active: root.hyprland\n        model: Hyprland.monitors#        active: false\n        model: Hyprland.monitors' \
  'shell/security/lock/Lock.qml#        onObjectAdded: Qt.callLater(root.monitorsAdded)\n#' \
  'shell/security/lock/Lock.qml#        if (holding)\n            requestMonitors();#        if (false)\n            requestMonitors();' \
  'shell/security/lock/Lock.qml#                Qt.callLater(root.checkOwnership);#                ;' \
  'shell/security/lock/Lock.qml#        } else if (state === "unlocked") {\n            strandedProbe.stop();#        } else if (state !== "locked") {\n            strandedProbe.stop();' \
  'shell/security/lock/Lock.qml#            if (!emptyModelLogged)\n                console.warn(#            if (true)\n                console.warn(' \
  'shell/security/lock/Lock.qml#            emptyModelLogged = true;#            ;' \
  'shell/security/lock/Lock.qml#        if (emptyModelLogged) {\n            emptyModelLogged = false;#        if (emptyModelLogged) {\n            ;' \
  'shell/security/lock/Lock.qml#        else if (strandedUndecided)\n            checkStranded();\n#' \
  'shell/security/lock/Lock.qml#        else if (strandedUndecided)\n            checkStranded();#        else if (strandedUndecided)\n            release();' \
  'shell/security/lock/Lock.qml#            strandedUndecided = true;\n#' \
  'shell/security/lock/Lock.qml#        strandedUndecided = false;\n        console.info("grassfield-lock: lock requested (#        console.info("grassfield-lock: lock requested (' \
  'shell/security/lock/Lock.qml#            strandedProbe.stop(); // still undecided#            strandedProbe.stop(); strandedUndecided = false; // still undecided' \
  'shell/platform/Displays.qml#    Component.onCompleted: {\n        publishDebounce.restart();#    Component.onCompleted: {\n        Hyprland.refreshMonitors();\n        publishDebounce.restart();' \
  'shell/platform/Compositor.qml#        const all = Hyprland.monitors ? Hyprland.monitors.values : [];#        Hyprland.refreshMonitors();\n        const all = Hyprland.monitors ? Hyprland.monitors.values : [];'; do
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
