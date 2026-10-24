#!/usr/bin/env bash
# Nested scenario (L1) for Show Desktop (GF-106, reviews of the shell UX batch). Bare command, nested session only.
#
# Part 1, ONE display. Whatever the nested session has (only GF-REF, or GF-REF with WAYLAND-1 beside it), the scenario runs on
# one output: the pointer is warped onto it (so focus-follows-mouse cannot move the focus to another output) and it uses two
# Spaces that no other output shows. The output used and the number of outputs are printed. Windows: A and B (foot, app id
# gf-sd-main) and C (foot, app id gf-sd-other) on Space S1; D on Space S2. Every way Show Desktop ends is checked for what it
# must leave behind: every window on its own Space, and the Space and the focus the user ended it with (never the old Space or
# the old focused window, except for the second press):
#   1 show: A, B, C parked on special:desktop, D untouched, record file written;
#   2 second press on the same Space: A, B, C back on S1, the Space is S1, the window that had the focus (C) has it;
#   3 Space switch: show, then S2: A, B, C back on S1, the active Space stays S2, the focus is D (never an old window);
#   4 new window: show, then a new foot E opens: A, B, C back, the focus is E;
#   5 activation (the switcher's next/release goes through Compositor.activate, as a Dock click does): show, switcher
#     next + release: every window back, the focus is the window of the other app (C), on its Space;
#   6 three presses in a row (0.45 s, 0.25 s): the verify of the second ending must not send the third's windows back;
#   7 an app activating a parked window (a `focus` dispatch on it, as focus_on_activate does for a client): everything comes
#     back, no special workspace stays shown over a screen, the activated window has the focus;
#   R crash recovery: show, then the shell is restarted (scripts/dev/shell-run.sh) with the windows parked: within the bound
#     (Tokens showDesktopRecoverMs + tries, 25 s here) every window is back on its Space, nothing was focused by the recovery
#     (the focus is what it was), nothing stays shown over a screen and the record file is gone.
# Steps 3 to 5 first check that the windows really were parked.
# Part 2, TWO displays (macOS: Show Desktop clears every display). A second headless output GF-SD2 is created (and removed at
# the end): P on the first display, Q on GF-SD2 (focused). Checks:
#   6 show: both windows parked, on both displays;
#   7 the pointer and the focus move to the other display: Show Desktop stays on (nothing comes back during 2 s);
#   8 a Space switch on GF-SD2: both windows back on their own Spaces, GF-SD2 keeps the new Space, nothing left parked;
#   9 show, the second press: both back, the focus is the window of the focused display (Q).
# The test closes every window it opened and removes GF-SD2, also when it fails or is interrupted (EXIT trap), and at the start
# it closes windows of an earlier run (app ids gf-sd-*). Only this tree's nested instance (scripts/dev/pidfile.sh); hyprctl is
# read-only except through scripts/nestctl; clients get the nested socket only.
# Expected: "show_desktop: 0 failure(s)" after PASS lines for every check. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "show_desktop: no verified nested instance (scripts/dev/nested-up.sh)"; exit 2; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "show_desktop: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "show_desktop: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
# The dev shell keeps its state under .dev/state (shell-run.sh sets GRASSFIELD_STATE_HOME): never the owner's home.
state=$dev/state/show-desktop.json
case $state in "$HOME"/.local/*) echo "show_desktop: the state file would be under $HOME/.local: refusing"; exit 2 ;; esac

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
nest() { "$root/scripts/nestctl" "$@"; }
space_of() { hq clients | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .workspace.name'; }
active_pid() { hq activewindow | jq -r '.pid'; }
active_space() { hq activeworkspace | jq -r '.name'; }
parked_count() { hq clients | jq '[.[] | select(.workspace.name == "special:desktop")] | length'; }
shown_space() { hq monitors | jq -r --arg m "$1" '.[] | select(.name == $m) | .activeWorkspace.name'; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" >/dev/null 2>&1; }
warp() { "$root/scripts/dev/pointer.sh" output "$1" abs 200 200 >/dev/null 2>&1; sleep 0.6; }
show_desktop() { ipc windows showDesktop; sleep 1.2; }
focus_space() { nest dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1; sleep 1; }

# Windows of this test: recorded without a subshell, closed by the EXIT trap and by the next run's start.
pids=()
NEWPID=""
open_foot() { # <app id> [output]: opens a foot with the pointer on the output; sets NEWPID to the window that has the focus
  [[ -n ${2:-} ]] && warp "$2"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.8
  NEWPID=$(active_pid)
}
close_test_windows() {
  local p pid
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-sd-")) | .pid'); do kill "$pid" 2>/dev/null; done
}
created_output=""
cleanup() {
  close_test_windows
  if [[ -n $created_output ]]; then nest output remove "$created_output" >/dev/null 2>&1; fi
  [[ -n ${S1:-} ]] && focus_space "$S1"
}
trap cleanup EXIT
close_test_windows
sleep 1

# Every check waits at most 6 s for the state to arrive (the shell restores from events), then reports what it saw.
wait_for() { local n; for n in $(seq 1 30); do "$@" && return 0; sleep 0.2; done; return 1; }
is_on_space() { [[ $(space_of "$1") == "$2" ]]; }
is_focus() { [[ $(active_pid) == "$1" ]]; }
is_space() { [[ $(active_space) == "$1" ]]; }
is_shown() { [[ $(shown_space "$1") == "$2" ]]; }
none_parked() { [[ $(parked_count) == 0 ]]; }
on_space() { wait_for is_on_space "$2" "$3" && pass "$1" || fail "$1: window $2 is on $(space_of "$2"), wanted $3"; }
focus_is() { wait_for is_focus "$2" && pass "$1" || fail "$1: focus is $(active_pid), wanted $2"; }
space_is() { wait_for is_space "$2" && pass "$1" || fail "$1: Space is $(active_space), wanted $2"; }
shown_is() { wait_for is_shown "$2" "$3" && pass "$1" || fail "$1: $2 shows $(shown_space "$2"), wanted $3"; }
nothing_parked() { wait_for none_parked && pass "$1" || fail "$1: $(parked_count) window(s) still on special:desktop"; }
has_record() { [[ -s $state ]] && grep -q '"records"' "$state"; }

# ---- the output for part 1 ---------------------------------------------------------------------------------------------
outputs=$(hq monitors | jq -r '.[].name' | paste -sd' ')
count=$(hq monitors | jq 'length')
if hq monitors | jq -e 'any(.[]; .name == "GF-REF")' >/dev/null; then OUT=GF-REF; else OUT=$(hq monitors | jq -r '.[0].name'); fi
echo "show_desktop: $count output(s) ($outputs); part 1 runs on $OUT only"
warp "$OUT"
S1=$(shown_space "$OUT")
maxid=$(hq monitors | jq '[.[].activeWorkspace.id] | max')
S2=$((maxid + 10))
[[ -n $S1 && $S1 != null ]] || { echo "show_desktop: no Space on $OUT"; exit 2; }

# ---- part 1: one display -----------------------------------------------------------------------------------------------
open_foot gf-sd-main "$OUT"; a=$NEWPID
open_foot gf-sd-main "$OUT"; b=$NEWPID
open_foot gf-sd-other "$OUT"; c=$NEWPID
focus_space "$S2"
open_foot gf-sd-main "$OUT"; d=$NEWPID
focus_space "$S1"
for p in "$a" "$b" "$c" "$d"; do [[ -n $p && $p != null ]] || { echo "show_desktop: could not open the windows"; exit 2; }; done
all_home() { # <label>
  on_space "$1: A on Space $S1" "$a" "$S1"
  on_space "$1: B on Space $S1" "$b" "$S1"
  on_space "$1: C on Space $S1" "$c" "$S1"
  on_space "$1: D still on Space $S2" "$d" "$S2"
  nothing_parked "$1: nothing left on special:desktop"
}
focus_is "setup: C has the focus on Space $S1" "$c"

# 1 show
show_desktop
for w in "$a" "$b" "$c"; do on_space "1: window $w parked" "$w" special:desktop; done
on_space "1: D on Space $S2 is not touched" "$d" "$S2"
wait_for has_record && pass "1: the record is in the state dir ($state)" || fail "1: no record in $state"

# 2 second press on the same Space
show_desktop
all_home "2"
space_is "2: the Space is $S1" "$S1"
focus_is "2: the window that had the focus (C) has it again" "$c"

# 3 Space switch
show_desktop
on_space "3: A was parked first" "$a" special:desktop
focus_space "$S2"
all_home "3"
space_is "3: the Space stays $S2 (the user is not pulled back)" "$S2"
focus_is "3: the focus is the Space $S2 window" "$d"
focus_space "$S1"

# 4 new window
show_desktop
on_space "4: A was parked first" "$a" special:desktop
open_foot gf-sd-main "$OUT"; e=$NEWPID
all_home "4"
on_space "4: E stays where it opened" "$e" "$S1"
focus_is "4: the new window keeps the focus" "$e"

# 5 activation (switcher next + release)
focus_space "$S1"
show_desktop
on_space "5: A was parked first" "$a" special:desktop
# The switcher orders its requests by hold id and ignores one it has already seen: a fresh id (the clock) per run, so that a
# second run against the same shell is not taken for a stale hold.
hold=$(date +%s)
ipc switcher next "$hold"
sleep 0.5
ipc switcher release "$hold"
all_home "5"
# The front app is gf-sd-main (E); the switcher's next app is gf-sd-other, whose only window is C: C must have the focus.
focus_is "5: the switcher's choice (C, the other app) has the focus, not the old window E" "$c"
space_is "5: the Space is C's Space" "$S1"

# 6 three presses in a row: the verify of the second must not send the third's windows back
focus_space "$S1"
ipc windows showDesktop
sleep 0.45
ipc windows showDesktop
sleep 0.25
ipc windows showDesktop
sleep 2.5
[[ $(parked_count) -ge 4 ]] && pass "6: after three quick presses Show Desktop is on and stays on ($(parked_count) windows parked)" || fail "6: only $(parked_count) window(s) parked after three quick presses"
show_desktop
all_home "6"

# 7 an app activating a parked window (focus_on_activate): everything comes back, nothing is left over the screen
show_desktop
on_space "7: A was parked first" "$a" special:desktop
addr_a=$(hq clients | jq -r --argjson p "$a" '.[] | select(.pid == $p) | .address')
nest dispatch "hl.dsp.focus({ window = \"address:$addr_a\" })" >/dev/null 2>&1
all_home "7"
no_special() { [[ $(hq monitors | jq '[.[] | select(.specialWorkspace.name != "")] | length') == 0 ]]; }
wait_for no_special && pass "7: the parking workspace is not shown over a screen" || fail "7: a special workspace is still shown"
focus_is "7: the window that was activated (A) has the focus" "$a"

# R crash recovery: the shell dies with the windows parked; the one that starts finds the record and sends them back
focus_space "$S1"
show_desktop
on_space "R: A was parked first" "$a" special:desktop
on_space "R: C was parked first" "$c" special:desktop
wait_for has_record && pass "R: the record is on disk before the restart" || fail "R: no record in $state"
focus_before=$(active_pid)
"$root/scripts/dev/shell-run.sh" >/dev/null 2>&1
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "show_desktop: the shell did not restart"; exit 2; }
recovered() { [[ $(parked_count) == 0 ]]; }
for n in $(seq 1 125); do recovered && break; sleep 0.2; done
recovered && pass "R: every window is back after the restart" || fail "R: $(parked_count) window(s) still parked 25 s after the restart"
on_space "R: A back on Space $S1" "$a" "$S1"
on_space "R: B back on Space $S1" "$b" "$S1"
on_space "R: C back on Space $S1" "$c" "$S1"
on_space "R: D still on Space $S2" "$d" "$S2"
on_space "R: E back on Space $S1" "$e" "$S1"
sleep 2
[[ $(active_pid) == "$focus_before" ]] && pass "R: the recovery focused nothing (the focus is still $focus_before)" || fail "R: the focus moved from $focus_before to $(active_pid)"
wait_for no_special && pass "R: no special workspace is shown over a screen" || fail "R: a special workspace is shown"
gone_record() { [[ ! -s $state ]] || ! grep -q '"windows"' "$state"; }
wait_for gone_record && pass "R: the record is removed" || fail "R: the record is still in $state"

# ---- part 2: two displays ----------------------------------------------------------------------------------------------
close_test_windows
sleep 1
if hq monitors | jq -e 'any(.[]; .name == "GF-SD2")' >/dev/null; then
  echo "show_desktop: GF-SD2 exists already; not creating it"
else
  nest output create headless GF-SD2 >/dev/null 2>&1
  created_output=GF-SD2
  sleep 2.5
fi
hq monitors | jq -e 'any(.[]; .name == "GF-SD2")' >/dev/null || { echo "show_desktop: could not create the second output (GF-SD2)"; exit 2; }
echo "show_desktop: part 2 uses $OUT and GF-SD2"
warp "$OUT"
T1=$(shown_space "$OUT")
warp GF-SD2
T2=$(shown_space GF-SD2)
[[ -n $T1 && -n $T2 && $T1 != "$T2" ]] || { echo "show_desktop: the two outputs show '$T1' and '$T2'"; exit 2; }
open_foot gf-sd-main "$OUT"; p=$NEWPID
open_foot gf-sd-other GF-SD2; q=$NEWPID
for w in "$p" "$q"; do [[ -n $w && $w != null ]] || { echo "show_desktop: could not open the two-display windows"; exit 2; }; done
on_space "setup: P is on $OUT's Space $T1" "$p" "$T1"
on_space "setup: Q is on GF-SD2's Space $T2" "$q" "$T2"
focus_is "setup: Q has the focus" "$q"

# 6 show
show_desktop
on_space "6: P (first display) parked" "$p" special:desktop
on_space "6: Q (second display) parked" "$q" special:desktop
wait_for has_record && pass "6: one record file for both displays" || fail "6: no record in $state"

# 7 pointer and focus move to the other display: Show Desktop stays on
warp "$OUT"
sleep 2
[[ $(space_of "$p") == special:desktop && $(space_of "$q") == special:desktop ]] && pass "7: moving the pointer and the focus to the other display ends nothing" || fail "7: P is on $(space_of "$p"), Q on $(space_of "$q")"
warp GF-SD2
sleep 1.5
[[ $(parked_count) == 2 ]] && pass "7: and back to the second display: both windows still parked" || fail "7: $(parked_count) window(s) parked, wanted 2"

# 8 a Space switch on the second display
other=$((S2 + 10))
focus_space "$other"
on_space "8: P back on its Space $T1" "$p" "$T1"
on_space "8: Q back on its Space $T2" "$q" "$T2"
shown_is "8: GF-SD2 keeps the new Space" GF-SD2 "$other"
nothing_parked "8: nothing left on special:desktop"
focus_space "$T2"

# 9 show and the second press: everything back, the focus is the focused display's window
warp GF-SD2
focus_is "9: setup: Q has the focus" "$q"
show_desktop
on_space "9: Q parked" "$q" special:desktop
show_desktop
on_space "9: P back" "$p" "$T1"
on_space "9: Q back" "$q" "$T2"
nothing_parked "9: nothing left on special:desktop"
focus_is "9: the focus is the focused display's window (Q)" "$q"

echo "show_desktop: $fails failure(s)"
exit $((fails > 0))
