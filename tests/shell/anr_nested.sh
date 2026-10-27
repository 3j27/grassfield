#!/usr/bin/env bash
# Nested scenario (L1) for "not responding" (ADR-0035 D-3; docs/specs/system-dialogs.md A-NR2). Bare command, nested session
# only. A foot window (app id gf-anr) is stopped with SIGSTOP, so it answers no ping: after misc.anr_missed_pings (3, about
# 4.5 s) Hyprland runs its dialog, which in this session is the repository's stand-in (config/hypr/dev.lua puts
# packaging/session-bin first in the nested compositor's PATH; the stand-in reports to the dev shell through
# GRASSFIELD_SHELL_DIR, dev plumbing). Checks:
#   1 within 12 s the shell marks the window's process (`anr status`, a dev hook) and no stock dialog runs (no
#     /usr/bin/hyprland-dialog process);
#   2 the stand-in waits, with the pid it reported, as the repository's packaging/session-bin/hyprland-dialog;
#   3 SIGCONT (the app answers again): within 4 s Hyprland killed the stand-in and the mark is gone;
#   4 stopped again until marked, then killed (what Force Quit does): within 4 s the mark is gone.
# The test closes the windows it opened (EXIT trap, and at the start those of an earlier run). Only this tree's nested
# instance (scripts/dev/pidfile.sh); hyprctl is read-only; clients get the nested socket only.
# Expected: "anr: 0 failure(s)" after PASS lines for every check. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP anr_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "anr: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "anr: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
command -v foot >/dev/null && command -v jq >/dev/null || { echo "anr: foot and jq are needed"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
status() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call anr status 2>/dev/null; }
marked() { [[ $(status | jq --argjson p "$1" '[.[] | select(.pid == $p)] | length' 2>/dev/null) == 1 ]]; }
not_marked() { [[ $(status | jq --argjson p "$1" '[.[] | select(.pid == $p)] | length' 2>/dev/null) == 0 ]]; }
standin_of() { status | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .standin' 2>/dev/null; }
# Stock dialogs of this nested instance: started by the stand-in (/usr/bin/hyprland-dialog) or by Hyprland itself when the
# stand-in is not in its PATH (hyprland-dialog), with this instance's signature in their environment.
stock_dialogs() {
  local p n=0
  for p in $(pgrep -u "$(id -u)" -f '^(/usr/bin/)?hyprland-dialog ' || true); do
    tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qx "HYPRLAND_INSTANCE_SIGNATURE=$sig" && n=$((n + 1))
  done
  echo "$n"
}
wait_for() { local secs=$1 n; shift; for ((n = 0; n < secs * 5; n++)); do "$@" && return 0; sleep 0.2; done; return 1; }

[[ $(status) == "["* ]] || { echo "anr: the dev shell has no anr target or refused its status (run this tree's shell)"; exit 2; }

pids=()
window_pid() { hq clients | jq -r --arg c "$1" '[.[] | select(.class == $c) | .pid] | first // empty'; }
open_foot() { # <app id>: sets WIN to the window's client pid
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  WIN=""
  local n
  for ((n = 0; n < 30; n++)); do
    sleep 0.2
    WIN=$(window_pid "$1")
    [[ -n $WIN ]] && break
  done
}
close_test_windows() {
  local p pid
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-anr")) | .pid'); do kill -CONT "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done
}
trap close_test_windows EXIT
close_test_windows
sleep 1

# 1-3: stop, mark, resume.
open_foot gf-anr-a
[[ -n $WIN ]] || { echo "anr: the test window did not open"; exit 2; }
kill -STOP "$WIN"
if wait_for 12 marked "$WIN"; then pass "1 a stopped app is marked as not responding (pid $WIN)"; else fail "1 no mark for pid $WIN within 12 s: $(status)"; fi
[[ $(stock_dialogs) == 0 ]] && pass "1 no stock dialog window opened" || fail "1 a stock \"not responding\" dialog opened"
standin=$(standin_of "$WIN")
if [[ -n $standin && $(tr '\0' ' ' <"/proc/$standin/cmdline" 2>/dev/null) == *"$root/packaging/session-bin/hyprland-dialog "* ]]; then
  pass "2 the stand-in ($standin) waits"
else
  fail "2 the stand-in '$standin' is not the repository's waiting hyprland-dialog"
fi
kill -CONT "$WIN"
if wait_for 4 not_marked "$WIN"; then pass "3 the app answers again: the mark is gone"; else fail "3 still marked 4 s after SIGCONT: $(status)"; fi
if [[ -n $standin ]] && ! kill -0 "$standin" 2>/dev/null; then pass "3 Hyprland ended the stand-in"; else fail "3 the stand-in $standin still runs"; fi

# 4: stop until marked, then kill the app.
kill -STOP "$WIN"
if wait_for 12 marked "$WIN"; then
  kill -KILL "$WIN"
  if wait_for 4 not_marked "$WIN"; then pass "4 the app was killed: the mark is gone"; else fail "4 still marked 4 s after the kill: $(status)"; fi
else
  fail "4 no mark for pid $WIN within 12 s (second hang)"
  kill -CONT "$WIN" 2>/dev/null
fi

echo "anr: $fails failure(s)"
((fails == 0))
