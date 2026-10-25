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

desc="the packaged helpers pass the gate (it is part of just check)"
check bash -c '[[ -z $(python3 -I "$1/scripts/dev/check-i18n.py" --helpers-only "$1/packaging/bin" 2>&1) ]]' _ "$root"

exit $fail
