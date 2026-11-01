#!/usr/bin/env bash
# Nested scenario (L1) for Activity Monitor's links with the shell: A-N1 (docs/specs/activity.md "Acceptance criteria";
# ADR-0038 AD48 to AD50, AM60 to AM62). Bare command, nested session only. This tree's app (.dev/build/grassfield-activity,
# built if missing) opens in the nested session with its Dock icon set to CPU Usage, beside a foot window (app id
# gf-act-a, title gf-act-secret-title). Checks:
#   1 the shell writes the projection (windows.json) in the nested display's runtime folder: the folder 0700, the file
#     0600, its writer the nested shell, the foot window's pid and app id in it, never a title;
#   2 foot stopped with SIGSTOP: within 12 s its pid is among the projection's not-responding pids (the ANR stand-in path of
#     ADR-0035), and gone within 8 s of SIGCONT;
#   3 `activity quit`: pid 1 "refused", a process without a window "no-windows", the foot's pid "ok" and its window closes;
#   4 the app writes dock-tile.json (0600, its writer the app, kind cpu-usage);
#   5 the app quits: both files are gone within 4 s.
# A-N2 (the dev guard refuses an action on a process outside the nested session) is driven through the window by A-W2's
# dev-guard case (tests/apps/activity_actions.sh); here, its precondition: the nested app runs as a dev session.
# The test closes what it opened (EXIT trap, and at the start what an earlier run left). Only this tree's nested instance
# (scripts/dev/pidfile.sh); hyprctl is read-only; clients get the nested socket only; the app's state is under .dev.
# Expected: "activity_nested: 0 failure(s)" after PASS lines for every check. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP activity_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "activity_nested: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "activity_nested: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
command -v foot >/dev/null && command -v jq >/dev/null || { echo "activity_nested: foot and jq are needed"; exit 2; }
[[ -n ${XDG_RUNTIME_DIR:-} ]] || { echo "activity_nested: XDG_RUNTIME_DIR is not set"; exit 2; }
bin=$dev/build/grassfield-activity
[[ -x $bin ]] || "$root/apps/activity/build-direct.sh" >/dev/null || { echo "activity_nested: the app did not build"; exit 2; }

# The display's folder, as ActivityLinkLogic.runtimeDir and runtimefiles.cpp name it.
display=${sock##*/}
folder=$XDG_RUNTIME_DIR/grassfield/activity-$(sed 's/[^A-Za-z0-9._-]/_/g' <<<"$display")
state=$dev/isolated/activity-nested/grassfield-state
case $state in "$dev"/*) ;; *) echo "activity_nested: unsafe state path"; exit 2 ;; esac

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
quit() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call activity quit "$1" 2>/dev/null; }
window_pid() { hq clients | jq -r --arg c "$1" '[.[] | select(.class == $c) | .pid] | first // empty'; }
wait_for() { local secs=$1 n; shift; for ((n = 0; n < secs * 5; n++)); do "$@" && return 0; sleep 0.2; done; return 1; }
projection() { cat "$folder/windows.json" 2>/dev/null; }
hung() { [[ $(projection | jq --argjson p "$1" '[.notResponding[] | select(. == $p)] | length' 2>/dev/null) == 1 ]]; }
not_hung() { [[ $(projection | jq --argjson p "$1" '[.notResponding[] | select(. == $p)] | length' 2>/dev/null) == 0 ]]; }
gone() { [[ ! -e $1 ]]; }
stat_start() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }

pids=()
app=""
close_all() {
  local p pid
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-act-")) | .pid'); do kill -CONT "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done
  [[ -n $app ]] && kill "$app" 2>/dev/null
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done
}
trap close_all EXIT
close_all
sleep 1

# The app opens with its Dock icon set to CPU Usage (AM62), its state under .dev.
mkdir -p -m 700 "$state"
printf '{"version": 1, "dockIcon": "cpu-usage"}\n' >"$state/activity.json"
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id gf-act-a --title gf-act-secret-title >/dev/null 2>&1 </dev/null &
pids+=($!)
WAYLAND_DISPLAY=$sock GRASSFIELD_SHELL_DIR=$root/shell setsid "$root/scripts/dev/isolated.sh" --name activity-nested --state-home "$state" "$bin" >/dev/null 2>&1 </dev/null &
pids+=($!)
wait_for 10 test -n "$(window_pid gf-act-a)" || { echo "activity_nested: the foot window did not open"; exit 2; }
wait_for 10 test -n "$(window_pid org.grassfield.Activity)" || { echo "activity_nested: the app's window did not open"; exit 2; }
foot_pid=$(window_pid gf-act-a)
app=$(window_pid org.grassfield.Activity)

# 1: the projection.
if wait_for 4 test -s "$folder/windows.json"; then
  [[ $(stat -c %a "$folder") == 700 && $(stat -c %a "$folder/windows.json") == 600 ]] && pass "1 the folder is 0700 and the projection 0600" \
    || fail "1 modes: folder $(stat -c %a "$folder"), file $(stat -c %a "$folder/windows.json")"
  [[ $(projection | jq -r '.writer.pid') == "$shell_pid" && $(projection | jq -r '.writer.start') == "$(stat_start "$shell_pid")" ]] \
    && pass "1 its writer is the nested shell" || fail "1 writer $(projection | jq -c '.writer'), shell $shell_pid"
  [[ $(projection | jq -r --argjson p "$foot_pid" '[.windows[] | select(.pid == $p) | .app] | first') == gf-act-a ]] \
    && pass "1 the foot window's pid and app id are in it" || fail "1 the foot window is missing: $(projection | jq -c '.windows')"
  projection | grep -q gf-act-secret-title && fail "1 a window title is in the projection" || pass "1 no title in it"
else
  fail "1 no projection in $folder within 4 s"
fi

# 2: not responding.
kill -STOP "$foot_pid"
if wait_for 12 hung "$foot_pid"; then pass "2 a stopped foot is among the not-responding pids"; else fail "2 not marked within 12 s: $(projection | jq -c '.notResponding')"; fi
kill -CONT "$foot_pid"
if wait_for 8 not_hung "$foot_pid"; then pass "2 it answers again: the mark is gone"; else fail "2 still marked 8 s after SIGCONT"; fi

# 3: activity quit.
[[ $(quit 1) == refused ]] && pass "3 pid 1 is refused" || fail "3 pid 1: '$(quit 1)'"
sleep 300 &
loner=$!
[[ $(quit "$loner") == no-windows ]] && pass "3 a process without a window: no-windows" || fail "3 a process without a window: '$(quit "$loner")'"
kill "$loner" 2>/dev/null
answer=$(quit "$foot_pid")
[[ $answer == ok ]] && pass "3 the foot's pid: ok" || fail "3 the foot's pid: '$answer'"
if wait_for 4 test -z "$(window_pid gf-act-a)"; then pass "3 its window closed"; else fail "3 the foot window is still open"; fi

# 4: the Dock tile's graph.
tile=$folder/dock-tile.json
if wait_for 12 test -s "$tile"; then
  [[ $(stat -c %a "$tile") == 600 ]] && pass "4 dock-tile.json is 0600" || fail "4 dock-tile.json mode $(stat -c %a "$tile")"
  [[ $(jq -r '.writer.pid' "$tile") == "$app" && $(jq -r '.kind' "$tile") == cpu-usage ]] && pass "4 its writer is the app, its kind cpu-usage" \
    || fail "4 dock-tile.json: $(jq -c '{writer, kind}' "$tile")"
else
  fail "4 no dock-tile.json within 12 s"
fi

# A-N2's precondition: the nested app is a dev session (its guard then refuses what descends from no dev root).
tr '\0' '\n' <"/proc/$app/environ" 2>/dev/null | grep -qx 'GRASSFIELD_DEV=1' && pass "A-N2 the nested app runs as a dev session" \
  || fail "A-N2 the nested app is not a dev session"

# 5: the app quits.
kill "$app"
if wait_for 4 gone "$tile" && wait_for 4 gone "$folder/windows.json"; then pass "5 the app quit: both files are gone"; else fail "5 left behind: $(ls "$folder" 2>/dev/null | tr '\n' ' ')"; fi
app=""

echo "activity_nested: $fails failure(s)"
((fails == 0))
