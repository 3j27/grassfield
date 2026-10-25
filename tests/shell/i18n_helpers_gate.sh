#!/usr/bin/env bash
# Selftest of part (e) of the i18n gate (scripts/dev/check-i18n.py --helpers-only DIR): the session helpers' strings. Each fixture
# helper is a tiny script in its own directory; the gate must pass the good ones, name the problem in each bad one, and must
# never run what it checks (a marker file that every fixture would create on import or execution must not appear).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/i18n-helpers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
gate() { python3 -I "$root/scripts/dev/check-i18n.py" --helpers-only "$1" 2>&1 || true; }
# fixture NAME FILENAME SHEBANG: body on stdin
fixture() { mkdir -p "$tmp/$1"; { echo "$3"; cat; } >"$tmp/$1/$2"; }

PYHEAD='import os
CATALOG = {"fr": {"Reopen": "Rouvrir", "Disk %s is full": "Le disque %s est plein"}}
def tr(text): return CATALOG["fr"].get(text, text)'

fixture good-py helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
open("$tmp/marker-py", "w").close()
def go(name):
    return ["notify-send", "-a", "Grassfield", "-u", "critical", "-i", "dialog-information", "-c", "device.error", "-t", "0",
            "-A", "reopen=" + tr("Reopen"), "--", tr("Disk %s is full") % name, tr("Reopen")]
EOF
fixture good-sh helper '#!/bin/sh' <<EOF
touch "$tmp/marker-sh"
lang=\${LANG%%[_.@]*}
tr() { case "\$lang:\$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "\$1" ;; esac; }
notify-send -a Grassfield -i dialog-information -A "default=\$(tr "Run")" -- "\$(tr "Run")" "\$body"
EOF
desc="a correct Python and a correct sh helper pass (icon names and other option values are not text)"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-py")$(gate "$tmp/good-sh")"
desc="the gate never runs what it reads: no marker file from the Python or the sh fixture"
check bash -c '[[ ! -e $1/marker-py && ! -e $1/marker-sh ]]' _ "$tmp"

fixture var helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go():
    title = "Disk is full right now"
    return ["notify-send", "--", title, tr("Reopen")]
EOF
desc="English text held in a variable (title = ...) is reported"
check grep -q 'title holds the bare English text' <<<"$(gate "$tmp/var")"

fixture literal helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "-a", "Grassfield", "--", "Hello there", tr("Reopen")]
EOF
desc="a bare English literal after -- is reported"
check grep -q "'Hello there' is a bare English literal" <<<"$(gate "$tmp/literal")"

fixture action helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "-A", "default=Run it now", "--", tr("Reopen")]
EOF
desc="a Python action label (-A default=Run it now) is reported"
check grep -q "action label 'default=Run it now'" <<<"$(gate "$tmp/action")"

fixture action2 helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(label): return ["notify-send", "-A", label, "--", tr("Reopen")]
EOF
desc="an action built from something that is not id= plus tr() is reported"
check grep -q 'action label is built from text' <<<"$(gate "$tmp/action2")"

fixture missing helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "--", tr("Not in the catalog")]
EOF
desc="a tr() string without French text is reported"
check grep -q "has no French text" <<<"$(gate "$tmp/missing")"

fixture constant helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
UNKNOWN_BODY = "Something went wrong with the thing"
ACTIONS = {"a": ("Do it anyway please", "x")}
def go(): return ["notify-send", "--", tr("Reopen")]
EOF
out=$(gate "$tmp/constant")
desc="module-level English text (a constant, a tuple in a dict) that is not in the catalog is reported"
check bash -c 'grep -q "Something went wrong" <<<"$1" && grep -q "Do it anyway please" <<<"$1"' _ "$out"

fixture nocat helper '#!/usr/bin/python3 -I' <<EOF
def go(): return ["notify-send", "--", "x"]
EOF
desc="a helper that notifies without CATALOG['fr'] is reported"
check grep -q "no CATALOG" <<<"$(gate "$tmp/nocat")"

fixture shact helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -a Grassfield -A default=Run -- "$(tr "Run")" "x"
EOF
desc="a shell action label (-A default=Run) is reported"
check grep -q "action label" <<<"$(gate "$tmp/shact")"

fixture shvar helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
body="Click to run it now"
notify-send -- "$(tr "Run")" "$body"
EOF
desc="English text held in a shell variable (body=...) is reported"
check grep -q "body holds the bare English text" <<<"$(gate "$tmp/shvar")"

fixture shlit helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -a Grassfield \
  -- "Pending Omarchy migrations" "$(tr "Run")"
EOF
desc="a bare English literal in a shell notify-send (also after a line continuation) is reported"
check grep -q "'Pending Omarchy migrations' is a bare English literal" <<<"$(gate "$tmp/shlit")"

fixture shmiss helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -- "$(tr "Run")" "$(tr "Stop")"
EOF
desc="a shell tr string without an fr: case is reported"
check grep -q 'tr .Stop. has no fr: case' <<<"$(gate "$tmp/shmiss")"
desc="none of the bad fixtures ran either"
check bash -c '[[ ! -e $1/marker-py && ! -e $1/marker-sh ]]' _ "$tmp"

# --- the shapes the first gate missed: conditionals, % and .format() and f-strings, variables that flow into notify-send ---
must_fail() { # NAME FILENAME SHEBANG PATTERN DESCRIPTION  (body on stdin)
  fixture "$1" "$2" "$3"
  desc="$5"
  check grep -q -- "$4" <<<"$(gate "$tmp/$1")"
}
must_fail cond helper '#!/usr/bin/python3 -I' 'title holds the bare English text' "a conditional of two English texts held in title is reported (both branches)" <<EOF
$PYHEAD
def go(critical):
    title = "Low battery" if not critical else "Very low battery"
    return ["notify-send", "--", title, tr("Reopen")]
EOF
must_fail cond-argv helper '#!/usr/bin/python3 -I' 'English text built in the code' "a conditional with English text directly in the argument list is reported" <<EOF
$PYHEAD
def go(x):
    return ["notify-send", "--", "Hello there" if x else tr("Reopen"), tr("Reopen")]
EOF
must_fail percent helper '#!/usr/bin/python3 -I' 'body holds the bare English text' "a % format of English text held in body is reported (the left side)" <<EOF
$PYHEAD
def go(label):
    body = "Can't %s now" % label.lower()
    return ["notify-send", "--", tr("Reopen"), body]
EOF
must_fail fstring helper '#!/usr/bin/python3 -I' 'English text built in the code' "an f-string (variable not in the watched names) flowing into notify-send is reported" <<EOF
$PYHEAD
def go(name):
    shown = f"Disk {name} is full"
    return ["notify-send", "--", tr("Reopen"), shown]
EOF
must_fail format helper '#!/usr/bin/python3 -I' 'English text built in the code' ".format() on English text in the argument list is reported" <<EOF
$PYHEAD
def go(name):
    return ["notify-send", "--", tr("Reopen"), "Disk {} is full".format(name)]
EOF
must_fail flow helper '#!/usr/bin/python3 -I' 'English text built in the code' "a variable with an unwatched name that holds English text and reaches notify-send is reported" <<EOF
$PYHEAD
def go():
    shown = "Something happened here"
    return ["notify-send", "--", tr("Reopen"), shown]
EOF
must_fail param helper '#!/usr/bin/python3 -I' 'is given the bare English text' "a local function called with English text for its title or body parameter is reported" <<EOF
$PYHEAD
def show(title, body):
    return ["notify-send", "--", title, body]
show("Hello there world", tr("Reopen"))
EOF
must_fail tr-cond helper '#!/usr/bin/python3 -I' 'has no French text' "tr() of a conditional: each branch needs French text" <<EOF
$PYHEAD
def go(x):
    return ["notify-send", "--", tr("Reopen" if x else "Not translated at all")]
EOF
# The old battery-watch (bc4a3c2) with a catalog that lacks its strings passed with 0 violations: it must fail.
must_fail old-battery helper '#!/usr/bin/python3 -I' 'English text' "the pre-fix battery-watch shape (conditional title, % body) with a catalog that lacks its strings is reported" <<EOF
import subprocess
CATALOG = {"fr": {"Other": "Autre"}}
def tr(text): return CATALOG["fr"].get(text, text)
def notify(level, capacity):
    critical = level <= 5
    title = "Low battery" if not critical else "Very low battery"
    body = "%d%% of the battery is left. Connect the charger%s." % (capacity, " now, the computer will shut down soon" if critical else "")
    subprocess.run(["notify-send", "-a", "Grassfield", "-u", "critical" if critical else "normal", "--", title, body], capture_output=True, timeout=10, check=False)
EOF
# The pre-fix session-end: the labels in a module-level table, "Can't %s now" % label.lower(), the bodies as variables.
fixture old-session-end helper '#!/usr/bin/python3 -I' <<EOF
import subprocess
CATALOG = {"fr": {"Other": "Autre"}}
def tr(text): return CATALOG["fr"].get(text, text)
ACTIONS = {"logout": ("Log Out", "Log Out Anyway"), "restart": ("Restart", "Restart Anyway")}
def ask(title, body, anyway):
    subprocess.Popen(["notify-send", "-a", "Grassfield", "-u", "critical", "-A", "force=" + anyway, "--", title, body])
def notify_blocked(action, names, unknown=False):
    label, anyway = ACTIONS[action]
    title = "Can't %s now" % label.lower()
    if unknown:
        body = "The list of open windows could not be read, so the session was not ended."
    else:
        body = "These applications are still open: %s." % ", ".join(names[:5])
    ask(title, body, anyway)
EOF
out=$(gate "$tmp/old-session-end")
desc="the pre-fix session-end shape is reported: the table's English, the % title and body, the English handed to ask(title, body)"
check bash -c 'grep -q "Log Out Anyway" <<<"$1" && grep -q "title holds the bare English text" <<<"$1" && grep -q "body holds the bare English text" <<<"$1"' _ "$out"
# Shell: a variable of any name that reaches notify-send, a one-line if, a printf format.
must_fail sh-msg helper '#!/bin/bash' "msg holds the bare English text" "a shell variable of any name that reaches notify-send (msg=...) is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
msg="Something went wrong here"
notify-send -- "$(tr "Run")" "$msg"
EOF
must_fail sh-oneline helper '#!/bin/bash' "note holds the bare English text" "a literal assigned inside a one-line if ... then ...; fi is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
if [ "$n" = 1 ]; then note="One thing happened"; else note=$(tr "Run"); fi
notify-send -- "$(tr "Run")" "$note"
EOF
must_fail sh-printf helper '#!/bin/bash' "shown holds the bare English text" "a printf whose format is English text and whose result reaches notify-send is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
shown=$(printf "Run %s things" "$n")
notify-send -- "$(tr "Run")" "$shown"
EOF
fixture good-sh2 helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run %s") printf '%s' "Exécuter %s" ;;
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
if [ "$n" = 1 ]; then note=$(tr "Run"); else note=$(printf "$(tr "Run %s")" "$n"); fi
notify-send -- "$(tr "Run")" "$note"
EOF
desc="a shell helper whose variables hold translated text (also through printf of a tr) passes"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-sh2")"
fixture good-py2 helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(critical, name):
    title = tr("Reopen" if critical else "Disk %s is full") % name
    shown = tr("Reopen") if critical else tr("Disk %s is full") % name
    return ["notify-send", "-i", "dialog-information", "--", title, shown, f"{name}"]
EOF
desc="a Python helper whose conditionals, % formats and f-strings only carry translated or dynamic text passes"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-py2")"

desc="the packaged helpers pass the gate (it is part of just check)"
check bash -c '[[ -z $(python3 -I "$1/scripts/dev/check-i18n.py" --helpers-only "$1/packaging/bin" 2>&1) ]]' _ "$root"

exit $fail
