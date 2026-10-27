#!/usr/bin/env bash
# ADR-0035 D-3: packaging/session-bin/hyprland-dialog, the stand-in Hyprland runs as its "Application Not Responding"
# dialog in a Grassfield session. An ANR call for exactly one client process is reported to the shell (`anr report`) and the
# stand-in then waits, silent, with the same pid (Hyprland kills it when the app answers or closes). Every other call, and
# every case where the window cannot be told apart or the shell does not say "ok" within 1 s, runs the stock dialog with the
# same arguments and the same pid. A scratch copy runs against fake `qs`, `hyprctl` and stock dialog;
# the texts are pinned against the installed Hyprland when there is one.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/hyprland-dialog.XXXXXX")
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
standin=$root/packaging/session-bin/hyprland-dialog

if ! command -v python3 >/dev/null; then
  echo "SKIP: python3 is not installed (the stand-in needs it; grassfield-desktop depends on python)"
  exit 0
fi

desc="the stand-in is executable and runs the stock dialog by absolute path"
check bash -c '[[ -x "$1" ]] && grep -qx "stock=/usr/bin/hyprland-dialog" "$1" && grep -qx "shell_dir=/usr/share/grassfield/shell" "$1"' _ "$standin"

# The scratch copy: only the stock dialog's path changes.
mkdir -p "$tmp/bin" "$tmp/fake"
sed "s|^stock=/usr/bin/hyprland-dialog\$|stock=$tmp/fake/stock|" "$standin" >"$tmp/bin/hyprland-dialog"
chmod +x "$tmp/bin/hyprland-dialog"
desc="the scratch copy differs from the stand-in by the stock path only"
check bash -c '[[ $(diff "$1" "$2" | grep -c "^[<>]") == 2 ]]' _ "$standin" "$tmp/bin/hyprland-dialog"

# Fake stock dialog: records its pid and arguments (one per NUL), prints nothing.
cat >"$tmp/fake/stock" <<'EOF'
#!/bin/sh
{ printf '%s\0' "$$"; for a; do printf '%s\0' "$a"; done; } >"$FAKE_DIR/stock.args"
exit 0
EOF
# Fake qs: records its arguments and the QS_* variables it sees, answers as FAKE_QS says.
cat >"$tmp/fake/qs" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" >"$FAKE_DIR/qs.args"
env | grep '^QS_' >"$FAKE_DIR/qs.env" || true
case "$FAKE_QS" in
  hang) exec sleep 5 ;;
  fail) echo "no running instance" >&2; exit 1 ;;
  *) printf '%s\n' "$FAKE_QS" ;;
esac
EOF
# Fake hyprctl: `-j clients` prints FAKE_CLIENTS.
cat >"$tmp/fake/hyprctl" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-j clients" ] && printf '%s\n' "$FAKE_CLIENTS"
EOF
chmod +x "$tmp/fake/stock" "$tmp/fake/qs" "$tmp/fake/hyprctl"

nl=$'\n'
en_text() { printf 'An application %s - %s is not responding.\nWhat do you want to do with it?' "$1" "$2"; }
fr_text() { printf "L'application %s - %s ne répond plus.\nQue voulez-vous faire?" "$1" "$2"; }
EN=("--title" "Application Not Responding")
FR=("--title" "L'application ne répond plus")
EN_B=("--buttons" "Terminate;Wait")
FR_B=("--buttons" "Forcer l'arrêt;Attendre")
clients() { # pid class title ...
  python3 -I -c 'import json, sys; a = sys.argv[1:]; print(json.dumps([{"pid": int(a[i]), "class": a[i + 1], "title": a[i + 2]} for i in range(0, len(a), 3)]))' "$@"
}

# Runs the stand-in in the background with these arguments. FAKE_QS and FAKE_CLIENTS come from the caller's environment.
# Sets `run_pid`; its stdout and stderr go to $tmp/out.
start() {
  rm -f "$tmp/stock.args" "$tmp/qs.args" "$tmp/qs.env"
  FAKE_DIR=$tmp PATH="$tmp/bin:$tmp/fake:/usr/bin:/bin" HYPRLAND_INSTANCE_SIGNATURE=${SIG-sig_1_2} \
    QS_CONFIG_NAME=stray QS_MANIFEST=/x QS_CONFIG_PATH=/y "$tmp/bin/hyprland-dialog" "$@" >"$tmp/out" 2>&1 &
  run_pid=$!
  pids+=("$run_pid")
}
# Waits up to $1 seconds for the run to end; true when it ended.
ended_within() {
  local i
  for ((i = 0; i < $1 * 20; i++)); do
    kill -0 "$run_pid" 2>/dev/null || { wait "$run_pid" 2>/dev/null || true; return 0; }
    sleep 0.05
  done
  return 1
}
# The NUL-separated record as lines, NULs shown as "|".
record() { tr '\0' '|' <"$tmp/$1"; }
# The stock dialog ran with the stand-in's pid and exactly these arguments.
ran_stock() {
  local want="$run_pid|"
  local a
  for a in "$@"; do want+="$a|"; done
  [[ -f $tmp/stock.args && $(record stock.args) == "$want" ]]
}
# The stand-in still runs with the pid Hyprland would kill (the script itself, no exec), and printed nothing.
waits_silently() {
  sleep 0.6
  kill -0 "$run_pid" 2>/dev/null && [[ $(tr '\0' ' ' <"/proc/$run_pid/cmdline" 2>/dev/null) == *"$tmp/bin/hyprland-dialog "* &&
    ! -s $tmp/out && ! -f $tmp/stock.args ]]
}
stop() { kill "$run_pid" 2>/dev/null || true; wait "$run_pid" 2>/dev/null || true; }

# 1. English ANR, one process, the shell says ok.
export FAKE_QS=ok FAKE_CLIENTS
FAKE_CLIENTS=$(clients 4242 foot "~" 5000 firefox "Mozilla Firefox")
start "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="en ANR for one process: the stand-in stays alive with its pid, prints nothing and runs no dialog"
check waits_silently
desc="it reported its own pid, the app's pid and the prefixed class, title and instance to the shell's anr target"
check bash -c '[[ $(tr "\0" "|" <"$1/qs.args") == "ipc|-p|/usr/share/grassfield/shell|call|anr|report|$2|4242|c:foot|t:~|i:sig_1_2|" ]]' _ "$tmp" "$run_pid"
desc="Quickshell's option variables were cleared before qs ipc"
check bash -c '[[ -f "$1/qs.env" && ! -s "$1/qs.env" ]]' _ "$tmp"
stop

# The shell's directory: GRASSFIELD_SHELL_DIR is dev plumbing (ADR-0019), honoured in a dev session only.
GRASSFIELD_DEV=1 GRASSFIELD_SHELL_DIR=/repo/shell start "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="a dev session (GRASSFIELD_DEV=1, no GRASSFIELD_SESSION): the report goes to the shell run from GRASSFIELD_SHELL_DIR"
check bash -c 'sleep 0.3; [[ $(tr "\0" "|" <"$1/qs.args") == "ipc|-p|/repo/shell|call|anr|report|"* ]]' _ "$tmp"
stop
GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1 GRASSFIELD_SHELL_DIR=/elsewhere start "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="a real session with a leaked GRASSFIELD_DEV=1 and GRASSFIELD_SHELL_DIR: the installed shell is asked"
check bash -c 'sleep 0.3; [[ $(tr "\0" "|" <"$1/qs.args") == "ipc|-p|/usr/share/grassfield/shell|call|anr|report|"* ]]' _ "$tmp"
stop
GRASSFIELD_SHELL_DIR=/elsewhere start "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="no run-mode variable, a stray GRASSFIELD_SHELL_DIR: the installed shell is asked"
check bash -c 'sleep 0.3; [[ $(tr "\0" "|" <"$1/qs.args") == "ipc|-p|/usr/share/grassfield/shell|call|anr|report|"* ]]' _ "$tmp"
stop

# 2. French ANR; a title with " - " and a leading "-" (qs would take a bare one for an option).
FAKE_CLIENTS=$(clients 4242 foot "~" 6100 firefox "-rw - notes.txt - Mozilla Firefox")
start "${FR[@]}" --text "$(fr_text "-rw - notes.txt - Mozilla Firefox" firefox)" "${FR_B[@]}"
desc="fr ANR: the stand-in waits silently"
check waits_silently
desc="fr ANR: the class is after the last \" - \", the title keeps its own, both prefixed"
check bash -c '[[ $(tr "\0" "|" <"$1/qs.args") == *"|report|$2|6100|c:firefox|t:-rw - notes.txt - Mozilla Firefox|i:sig_1_2|" ]]' _ "$tmp" "$run_pid"
stop

# 3. An untitled window: Hyprland names it "(unknown)".
FAKE_CLIENTS=$(clients 4242 foot "" 4300 foot "(other)")
start "${EN[@]}" --text "$(en_text "(unknown)" foot)" "${EN_B[@]}"
desc="an untitled window: the stand-in waits silently"
check waits_silently
desc="an untitled window (\"(unknown)\" in Hyprland's text) is found by its empty title, and reported with it"
check bash -c '[[ $(tr "\0" "|" <"$1/qs.args") == *"|$2|4242|c:foot|t:|"* ]]' _ "$tmp" "$run_pid"
stop

# A class may hold " - " too (an app sets its own app id): every split is tried.
FAKE_CLIENTS=$(clients 4242 "z - victim" "Victim" 5000 firefox "Mozilla Firefox")
start "${EN[@]}" --text "$(en_text "Victim" "z - victim")" "${EN_B[@]}"
desc="a class holding \" - \": the stand-in waits silently"
check waits_silently
desc="a class holding \" - \" is reported whole"
check bash -c '[[ $(tr "\0" "|" <"$1/qs.args") == *"|$2|4242|c:z - victim|t:Victim|"* ]]' _ "$tmp" "$run_pid"
stop

# The stand-in's stdout is Hyprland's pipe: nothing else may hold it, or Hyprland would read no end when it kills the
# stand-in. And a compositor that is gone kills nothing: the stand-in ends once its parent did.
FAKE_CLIENTS=$(clients 4242 foot "~")
rm -f "$tmp/qs.args" "$tmp/eof"
( FAKE_DIR=$tmp PATH="$tmp/bin:$tmp/fake:/usr/bin:/bin" HYPRLAND_INSTANCE_SIGNATURE=sig_1_2 \
    "$tmp/bin/hyprland-dialog" "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}" 2>/dev/null ) |
  { cat >/dev/null; date +%s%N >"$tmp/eof"; } &
pids+=($!)
for ((i = 0; i < 40; i++)); do [[ -s $tmp/qs.args ]] && break; sleep 0.05; done
sleep 2.5 # past the first poll of its parent, so a poll's child is running
standin_pid=$(tr '\0' '\n' <"$tmp/qs.args" 2>/dev/null | sed -n 7p)
desc="the waiting stand-in holds Hyprland's pipe alone: SIGKILL ends the pipe within 0.5 s"
check bash -c 't0=$(date +%s%N); kill -KILL "$2"; for ((i = 0; i < 40; i++)); do [[ -s $1/eof ]] && break; sleep 0.05; done;
  [[ -s $1/eof && $(( ($(cat "$1/eof") - t0) / 1000000 )) -lt 500 ]]' _ "$tmp" "$standin_pid"
wait "${pids[-1]}" 2>/dev/null || true
rm -f "$tmp/qs.args"
FAKE_DIR=$tmp PATH="$tmp/bin:$tmp/fake:/usr/bin:/bin" HYPRLAND_INSTANCE_SIGNATURE=sig_1_2 \
  bash -c '"$0" "$@" & wait' "$tmp/bin/hyprland-dialog" "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}" >/dev/null 2>&1 &
parent=$!
pids+=("$parent")
for ((i = 0; i < 40; i++)); do [[ -s $tmp/qs.args ]] && break; sleep 0.05; done
standin_pid=$(tr '\0' '\n' <"$tmp/qs.args" 2>/dev/null | sed -n 7p)
desc="the stand-in ends within 3 s once its parent (the compositor) is gone"
# (Ended: gone, or a zombie its new parent has not reaped yet; a container's init may never reap it.)
check bash -c 'runs() { local st; st=$(cut -d" " -f3 "/proc/$1/stat" 2>/dev/null) && [[ $st != Z ]]; }
  [[ -n $2 ]] && runs "$2" && kill -KILL "$1" || exit 1
  for ((i = 0; i < 60; i++)); do runs "$2" || exit 0; sleep 0.05; done; exit 1' _ "$parent" "$standin_pid"
wait "$parent" 2>/dev/null || true

# 4. Text with a newline inside the title, and no Hyprland instance in the environment.
FAKE_CLIENTS=$(clients 4242 foot "a${nl}b")
SIG='' start "${EN[@]}" --text "$(en_text "a${nl}b" foot)" "${EN_B[@]}"
desc="a title holding a newline: the stand-in waits silently"
check waits_silently
desc="a title holding a newline is matched whole; an empty instance is passed as \"i:\" (the shell refuses it)"
check bash -c '[[ $(tr "\0" "|" <"$1/qs.args") == *"$2" ]]' _ "$tmp" "|4242|c:foot|t:a${nl}b|i:|"
stop

# The calls that go to the stock dialog. Each: the stock dialog ran at once with the same pid and arguments, and printed
# nothing of its own.
falls_back() { # what, seconds, args...
  local what=$1 secs=$2
  shift 2
  start "$@"
  desc="$what: the stock dialog runs with the same pid and arguments"
  if ended_within "$secs"; then
    check ran_stock "$@"
  else
    echo "FAIL: $desc (still running after ${secs}s)"
    fail=1
    stop
  fi
}

FAKE_CLIENTS=$(clients 4242 foot "~" 4300 foot "~")
falls_back "two processes with the same class and title" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="... and the shell was not asked"
check test ! -e "$tmp/qs.args"

# An app that names itself after another app's window (class "victim", title "Victim - z") while the hung one is class
# "z - victim", title "Victim": two splits match two processes, so the mark cannot go to either.
FAKE_CLIENTS=$(clients 4242 "z - victim" "Victim" 77 victim "Victim - z")
falls_back "a window named to match another split" 2 "${EN[@]}" --text "$(en_text "Victim" "z - victim")" "${EN_B[@]}"
desc="... and the shell was not asked"
check test ! -e "$tmp/qs.args"
FAKE_CLIENTS=$(clients 4242 foot "" 4242 foot "(unknown)")
falls_back "one process with an untitled window and one titled \"(unknown)\"" 2 "${EN[@]}" --text "$(en_text "(unknown)" foot)" "${EN_B[@]}"

FAKE_CLIENTS=$(clients 5000 firefox "Mozilla Firefox")
falls_back "no window with this class and title" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"

FAKE_CLIENTS=$(clients 1 foot "~")
falls_back "a pid of 1" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
FAKE_CLIENTS='[{"pid": null, "class": "foot", "title": "~"}]'
falls_back "a pid that is not a number" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
FAKE_CLIENTS='not json'
falls_back "an unreadable client list" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"

FAKE_CLIENTS=$(clients 4242 foot "~")
FAKE_QS="refused" falls_back "the shell refuses" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="... after asking it"
check test -e "$tmp/qs.args"
FAKE_QS=fail falls_back "no shell answers" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
FAKE_QS="" falls_back "an empty answer" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
t0=$(date +%s%N)
FAKE_QS=hang falls_back "a shell that hangs (1-s deadline)" 3 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}"
desc="... within 2 s"
check test $((($(date +%s%N) - t0) / 1000000)) -lt 2000

falls_back "another language" 2 --title "Anwendung reagiert nicht" --text "Eine Anwendung ~ - foot reagiert nicht." --buttons "Beenden;Warten"
falls_back "English title with French buttons" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${FR_B[@]}"
falls_back "a text that is not the template" 2 "${EN[@]}" --text "An application ~ - foot hangs." "${EN_B[@]}"
falls_back "a text without \" - \"" 2 "${EN[@]}" --text "$(printf 'An application foot is not responding.\nWhat do you want to do with it?')" "${EN_B[@]}"
falls_back "an empty class" 2 "${EN[@]}" --text "$(en_text "~" "")" "${EN_B[@]}"
falls_back "Safe Mode's dialog" 2 --title "Safe Mode" --text "Hyprland has launched in safe mode." --buttons "Load config;Open crash report;Understood"
falls_back "a permission prompt" 2 --title "Permission request" --text "An application wants to capture your screen." --buttons "Deny;Allow once;Allow"
falls_back "the arguments in another order" 2 --text "$(en_text "~" foot)" "${EN[@]}" "${EN_B[@]}"
falls_back "an extra argument" 2 "${EN[@]}" --text "$(en_text "~" foot)" "${EN_B[@]}" --extra
falls_back "no arguments" 2
falls_back "--help" 2 --help

# The texts are Hyprland's: pinned against the installed binary, read from the stand-in itself (a copy whose texts were
# changed must fail the same check).
pinned() { # stand-in, Hyprland binary
  bash -c '
    eval "$(sed -n "/^nl=/,/^fr_unknown=/p" "$1")"
    python3 -I - "$2" "$en_title" "${en_head}{title} - {class}${en_tail}" "${en_buttons%%;*}" "${en_buttons#*;}" "$en_unknown" \
      "$fr_title" "${fr_head}{title} - {class}${fr_tail}" "${fr_buttons%%;*}" "${fr_buttons#*;}" "$fr_unknown" <<"PY"
import sys
data = open(sys.argv[1], "rb").read()
missing = [s for s in sys.argv[2:] if s.encode() + b"\0" not in data]
if missing:
    print("missing from Hyprland:", missing)
sys.exit(1 if missing else 0)
PY' _ "$@"
}
hyprland=$(command -v Hyprland || true)
if [[ -n $hyprland && -r $hyprland ]]; then
  desc="the stand-in's en_US and fr_FR texts are the installed Hyprland's ($hyprland)"
  check pinned "$standin" "$hyprland"
  sed 's/^fr_tail=.*/fr_tail=" ne répond pas.${nl}Que voulez-vous faire?"/' "$standin" >"$tmp/changed"
  desc="control: a stand-in with one changed text fails that check"
  changed_fails() { ! cmp -s "$standin" "$tmp/changed" && ! pinned "$tmp/changed" "$hyprland" >/dev/null; }
  check changed_fails
else
  echo "SKIP: no installed Hyprland to pin the texts against"
fi

exit "$fail"
