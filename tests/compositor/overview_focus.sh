#!/usr/bin/env bash
# Overview close focus (docs/specs/overview.md "Close focus", feature overview-focus, owner decision 2026-10-19 batch 5): the
# shell names what gets the keyboard when the Overview closes and the plugin focuses it once no Exclusive layer surface is
# left. Hyprland 0.56.2 refuses window focus while any Exclusive layer is mapped and does not retry when the last one goes
# (with two outputs the keyboard was lost after a close); the protocol activate does nothing for the still-focused window.
#
# Usage: tests/compositor/overview_focus.sh [check|baseline] [--plugin PATH]
#   check     the loaded plugin advertises overview-focus: every check must pass (exit 0), else exit 1
#   baseline  the loaded plugin does not (an older build loaded with scripts/nestctl plugin load, or a session started with
#             scripts/dev/nested-up.sh --no-plugin, C2): the same cases run, the verb is a no-op (the shell's guarded
#             call; nothing emulates the shell's own focus action); focus checks may fail (they show what the plugin
#             fixes); exit 1 only when a SAFETY check fails (a letter in a released chrome or in the dialog when it is not
#             the target, a window focused under the lock, Hyprland gone, an output resized)
#   --plugin PATH  the build loaded in the nested session (default compositor/build/grassfield-compositor.so); case 14
#             unloads and loads that file. A plugin unloaded while appmenu clients are alive stays mapped (FR23): loading the
#             same path again gets the same library, so a rebuilt plugin needs a new nested session (or another path).
# NESTED only, run BARE (never chained or with a VAR= prefix): needs this tree's nested session (scripts/dev/nested-up.sh).
# Two HEADLESS outputs: GF-REF (1920x1080, from config/hypr/dev.lua) and GF-REF2 (1440x900 at 1920,0, created here and
# removed at the end); WAYLAND-1 (the nested window, sized by the owner's session) is disabled for the run and enabled
# again at the end, all through scripts/nestctl. The shell's chromes are stood in for by tests/compositor/overview-focus-
# fixture (an Exclusive Overlay chrome per output released in a given order, and a polkit-like dialog), driven over
# Quickshell IPC; the lock by tests/security/foreign_locker/ForeignLocker.qml (released over its IPC, nothing is ever typed
# while locked). Windows: foot capture windows (raw tty, every typed byte to a file) through scripts/dev/isolated.sh; keys
# through scripts/dev/keys.sh (letters only), the pointer through scripts/dev/pointer.sh. Only processes started here are
# stopped.
#
# Cases (each: a start window focused, both chromes Exclusive, one holds the keyboard, the request, the release, letters):
#   1-3  remembered A (the window active at open, still Hyprland's focused window): release holder first (Hyprland's own
#        refocus is refused), holder last, both together -> A gets the keys
#   4-5  window B on the other output: holder first; holder first with the chromes unmapping -> B
#   6    Desktop shown: A's Desktop with A active (the current Desktop), B's Desktop on the other output -> its front window
#   7    another Desktop (not shown, window C on it) -> its monitor shows it (Hyprland's own switch), C gets the keys; the
#        Desktops shown before are switched back afterwards
#   8    window E chosen, E closed during the close (the pointer on GF-REF: Hyprland moves the monitor focus to the
#        pointer's output when the focused window closes) -> fallback: the focused Desktop's front window A, outcome
#        fallback/gone
#   9    remembered D, D minimized during the close -> fallback A (minimized), D never gets a key
#   10   a press beside the remaining Exclusive chrome on the other output's window -> that window wins (target press)
#   11   a polkit-like dialog appears during the close and stays past the bound: letters go to its field, no window gets
#        one, outcome timeout; 12 a short dialog: nothing focused while it is up, A after it
#   13   invalid payloads -> outcome invalid; 300 requests in one dispatch -> one outcome, the socket2 subscriber alive
#   14   plugin unload while a request waits -> outcome unavailable, Hyprland alive, reload brings overview-focus back
#   15   the session lock arriving during the close -> outcome refused, no window focused; nothing typed; unlocked by IPC
# Logs: .dev/overview-focus/run-<timestamp>-<mode>/. Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
plugin=$root/compositor/build/grassfield-compositor.so
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --plugin) plugin=${2:?--plugin needs a path}; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
mode=${args[0]:-check}
case $mode in
  check | baseline) ;;
  *) echo "usage: overview_focus.sh [check|baseline] [--plugin PATH]" >&2; exit 2 ;;
esac

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "overview_focus: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "overview_focus: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat jq foot qs; do
  command -v "$tool" >/dev/null || { echo "overview_focus: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
features() { nestctl -j grassfield 2>/dev/null | jq -c '.features' 2>/dev/null || echo "none (no plugin)"; }
has_feature() { nestctl -j grassfield 2>/dev/null | jq -e --arg f "$1" '.features | index($f)' >/dev/null 2>&1; }
if [[ $mode == check ]] && ! has_feature overview-focus; then
  echo "overview_focus: the loaded plugin does not advertise \"overview-focus\" (baseline mode is for that)" >&2
  exit 2
fi
if [[ $mode == baseline ]] && has_feature overview-focus; then
  echo "overview_focus: baseline needs a session without overview-focus (an older build or --no-plugin)" >&2
  exit 2
fi

run=$dev/overview-focus/run-$(date +%Y%m%d-%H%M%S)-$mode
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
fixlog=$run/fixture.log
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
fixture_bus=disabled:
[[ -s $dev/bus.address ]] && fixture_bus=$(head -n 1 "$dev/bus.address")
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$1" "${@:2}" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" -s 150 "$@" >>"$log" 2>&1; }

pids=()
socat_pid="" fixture_pid="" locker_pid="" plugin_unloaded=0 headless=0
fx() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$fixture_pid" call ovf "$@" 2>>"$log"; }
foreign_ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }

OUT_A=GF-REF
OUT_B=GF-REF2
mon_sizes() { nestctl monitors -j | jq -r '[.[] | "\(.name)=\(.width)x\(.height)"] | sort | join(" ")'; }
# Lua monitor rule through the nested instance (hl.dispatch's "expected a dispatcher" error is harmless: the rule applied).
monrule() { nestctl dispatch "hl.monitor($1)" >/dev/null 2>&1 || true; sleep 0.8; }
headless_up() {
  nestctl monitors all -j | jq -e --arg n "$OUT_B" 'any(.[]; .name == $n)' >/dev/null || nestctl output create headless "$OUT_B" >/dev/null
  sleep 0.8
  monrule '{ output = "WAYLAND-1", disabled = true }'
  monrule "{ output = \"$OUT_A\", mode = \"1920x1080@60\", position = \"0x0\", scale = 1 }"
  monrule "{ output = \"$OUT_B\", mode = \"1440x900@60\", position = \"1920x0\", scale = 1 }"
  sleep 2 # the shell creates its per-output surfaces on the new output
}
headless_down() {
  nestctl output remove "$OUT_B" >/dev/null 2>&1 || true
  monrule '{ output = "WAYLAND-1", mode = "1440x900", position = "auto", scale = 1 }'
  monrule "{ output = \"$OUT_A\", mode = \"1920x1080@60\", position = \"auto-right\", scale = 1 }"
}

cleanup() {
  if [[ -n $locker_pid ]] && kill -0 "$locker_pid" 2>/dev/null; then
    foreign_ipc unlock >/dev/null # never leave the nested session locked
    sleep 0.5
    kill "$locker_pid" 2>/dev/null
  fi
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  ((plugin_unloaded)) && nestctl plugin load "$plugin" >/dev/null 2>&1 # never leave the session without the plugin
  ((headless)) && headless_down
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
}
trap cleanup EXIT

stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!

fail=0 passed=0 total=0 safety_fail=0
# check <label> <status> [detail]: a focus check. safe <label> <status> [detail]: a safety check (also fails a baseline).
check() {
  total=$((total + 1))
  if [[ $2 == 0 ]]; then passed=$((passed + 1)); say "  PASS $1${3:+ ($3)}"; else say "  FAIL $1${3:+ ($3)}"; fail=1; fi
}
safe() {
  total=$((total + 1))
  if [[ $2 == 0 ]]; then passed=$((passed + 1)); say "  PASS [safety] $1${3:+ ($3)}"; else say "  FAIL [safety] $1${3:+ ($3)}"; fail=1; safety_fail=1; fi
}

# ---- windows ----
foot_capture() { # <app id> <capture> -> pid
  : >"$2"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name overview-focus foot --app-id="$1" --window-size-pixels=640x400 \
    -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$2" >/dev/null 2>&1 </dev/null &
  echo $!
}
address_of() { # <pid> -> address (0x...) of its mapped window, waits up to 5 s
  local a="" i
  for i in $(seq 1 50); do
    a=$(nestctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p and .mapped)][0].address // ""')
    [[ -n $a ]] && break
    sleep 0.1
  done
  echo "$a"
}
ws_of_output() { nestctl -j monitors | jq -r --arg o "$1" '.[] | select(.name == $o) | .activeWorkspace.id'; }
ws_of_window() { nestctl -j clients | jq -r --arg a "$1" '.[] | select(.address == $a) | .workspace.id'; }
move_to_ws() { nestctl dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.3; }
focus_window() { nestctl dispatch "hl.dsp.focus({ window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.3; }
focus_ws() { nestctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >>"$log" 2>&1; sleep 0.4; }
active_window() { nestctl -j activewindow 2>/dev/null | jq -r '.address // ""'; }
center_of() { # <address> -> "<output> <x> <y>" (output-local) of the window's surface centre
  local mons
  mons=$(nestctl -j monitors)
  nestctl -j clients | jq -r --argjson mons "$mons" --arg a "$1" '.[] | select(.address == $a) as $w
    | ($mons[] | select(.id == $w.monitor)) as $m
    | "\($m.name) \(($w.at[0] + $w.size[0] / 2 - $m.x) | floor) \(($w.at[1] + $w.size[1] / 2 - $m.y) | floor)"'
}
hexof() { echo "${1#0x}"; }

# ---- overview-focus events ----
ovf_events() { grep -a 'grassfield>>{"v":"gfc/1","type":"overview-focus"' "$events" 2>/dev/null; }
outcome_of() { # <id> -> the last non-pending event of that request (JSON), or ""
  ovf_events | sed 's/^[0-9]* grassfield>>//' | jq -c --argjson id "$1" 'select(.id == $id and .outcome != "pending")' 2>/dev/null | tail -n 1
}
wait_outcome() { # <id> <ms> -> JSON
  local deadline=$(($(date +%s%3N) + $2)) j=""
  while :; do
    j=$(outcome_of "$1")
    [[ -n $j ]] && break
    (($(date +%s%3N) > deadline)) && break
    sleep 0.05
  done
  echo "$j"
}
# The request as the shell sends it: the verb is called only when the plugin registered it (a no-op otherwise).
request() { nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview_focus then p.overview_focus([[$1]]) end end" >>"$log" 2>&1; }

# ---- the fixture (chromes and polkit-like dialog) ----
start_fixture() {
  : >"$fixlog"
  GF_OF_OUTPUT_A=$OUT_A GF_OF_OUTPUT_B=$OUT_B WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name overview-focus-fixture qs -p "$root/tests/compositor/overview-focus-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  local i
  for i in $(seq 1 60); do
    grep -q "\[ovf-fixture\] outputs" "$fixlog" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5
  grep -q "\[ovf-fixture\] outputs $OUT_A found $OUT_B found" "$fixlog"
}
fix_count() { grep -c "\[ovf-fixture\] $1" "$fixlog" 2>/dev/null; } # <pattern>
# Both chromes Exclusive; prints the output whose chrome holds the keyboard ("" when none did within 3 s).
open_chromes() {
  local h="" i
  fx open >/dev/null
  for i in $(seq 1 60); do
    h=$(fx holder)
    [[ -n $h ]] && break
    sleep 0.05
  done
  sleep 0.2
  echo "$h"
}
release() { fx release "$1" "$2" "$3" >/dev/null; } # <order> <gapMs> <unmapMs>

# ---- typing ----
caps=()
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
# type_to <label> <expected sink: a capture path, "polkit" or "none"> <letters>: the letters reach that sink and no other.
type_to() {
  local label=$1 want=$2 tag=$3 c i
  local -A before=()
  for c in "${caps[@]}"; do before[$c]=$(size_of "$c"); done
  local chrome0 polkit0
  chrome0=$(fix_count "chrome key") polkit0=$(fix_count "polkit key")
  keys "$tag"
  local got=1
  for i in $(seq 1 40); do
    if [[ $want == polkit ]]; then
      (($(fix_count "polkit key") - polkit0 >= ${#tag})) && { got=0; break; }
    elif [[ $want != none ]]; then
      tail -c +"$((before[$want] + 1))" "$want" | grep -q "$tag" && { got=0; break; }
    fi
    sleep 0.05
  done
  sleep 0.3
  # Another window than the target: a focus failure (Hyprland's own refocus without the plugin picks the last window). A
  # released chrome or the dialog when it is not the target: a safety failure in every mode.
  local stray="" unsafe="" n
  for c in "${caps[@]}"; do
    [[ $c == "$want" ]] && continue
    n=$(($(size_of "$c") - before[$c]))
    ((n > 0)) && stray+=" $(basename "$c" .cap)+$n"
  done
  n=$(($(fix_count "chrome key") - chrome0))
  ((n > 0)) && unsafe+=" chrome+$n"
  if [[ $want != polkit ]]; then
    n=$(($(fix_count "polkit key") - polkit0))
    ((n > 0)) && unsafe+=" polkit+$n"
  fi
  local where="lost"
  ((got == 0)) && where="arrived"
  [[ $want == none ]] && where="not expected anywhere"
  if [[ $want != none ]]; then check "$label: \"$tag\" reaches $(basename "$want" .cap)" "$got" "$where"; fi
  [[ -z $stray ]]; check "$label: no letter in another window" $? "${stray:-none}"
  [[ -z $unsafe ]]; safe "$label: no letter in a released chrome or the dialog" $? "${unsafe:-none}"
}
outcome_is() { # <label> <id> <outcome> [address]: the request's final event
  local j addr
  j=$(wait_outcome "$2" 2500)
  addr=$(jq -r '.address // ""' <<<"$j" 2>/dev/null)
  local ok=1
  if [[ -n $j && $(jq -r '.outcome' <<<"$j") == "$3" ]] && [[ -z ${4:-} || $addr == "$(hexof "$4")" ]]; then ok=0; fi
  check "$1: outcome $3${4:+ ($4)}" "$ok" "${j:-no event}"
}

# ---- setup ----
say "overview-focus $mode: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), plugin features $(features)"
headless=1
headless_up
start_sizes=$(mon_sizes)
say "outputs: $start_sizes"
[[ $start_sizes == "$OUT_B=1440x900 $OUT_A=1920x1080" ]] || { say "INVALID RUN: expected only $OUT_A and $OUT_B, got: $start_sizes"; exit 2; }
start_fixture || { say "fixture did not start"; cat "$fixlog" >>"$log"; exit 2; }

# The pointer rests on empty desktop at the right edge of GF-REF2 (no window under it); new windows open centred on the
# output under the pointer, so each one is moved to its Desktop explicitly.
park() { pointer "$OUT_B" abs 1430 120 sleep 80; }
park
cap_a=$run/capture-a.cap cap_b=$run/capture-b.cap cap_c=$run/capture-c.cap cap_d=$run/capture-d.cap cap_e=$run/capture-e.cap
caps=("$cap_a" "$cap_b" "$cap_c" "$cap_d" "$cap_e")
ws_a=$(ws_of_output "$OUT_A") ws_b=$(ws_of_output "$OUT_B")
ws_c=$(nestctl -j workspaces | jq '[.[].id | select(. > 0)] | max + 5')
p=$(foot_capture gf-ovf-a "$cap_a"); pids+=("$p"); addr_a=$(address_of "$p")
p=$(foot_capture gf-ovf-b "$cap_b"); pids+=("$p"); addr_b=$(address_of "$p")
p=$(foot_capture gf-ovf-c "$cap_c"); pids+=("$p"); addr_c=$(address_of "$p")
p=$(foot_capture gf-ovf-d "$cap_d"); pids+=("$p"); pid_d=$p; addr_d=$(address_of "$p")
for a in "$addr_a" "$addr_b" "$addr_c" "$addr_d"; do [[ -n $a ]] || { say "a capture window did not map"; exit 2; }; done
move_to_ws "$addr_a" "$ws_a"
move_to_ws "$addr_d" "$ws_a"
move_to_ws "$addr_b" "$ws_b"
move_to_ws "$addr_c" "$ws_c"
say "setup: A $addr_a and D $addr_d on $OUT_A Desktop $ws_a, B $addr_b on $OUT_B Desktop $ws_b, C $addr_c on Desktop $ws_c (not shown)"
focus_window "$addr_d"
focus_window "$addr_a" # A above D
[[ $(ws_of_output "$OUT_A") == "$ws_a" && $(ws_of_window "$addr_c") == "$ws_c" ]] || { say "INVALID RUN: Desktops not as set up"; exit 2; }

id=0
# One close: the start window focused, both chromes Exclusive, the request, the release.
close_with() { # <start window> <request JSON without id> <order> <gapMs> <unmapMs>
  park
  focus_window "$1"
  holder=$(open_chromes)
  id=$((id + 1))
  request "${2%\}},\"id\":$id}"
  release "$3" "$4" "$5"
  sleep "$(awk -v g="$4" -v u="$5" 'BEGIN { t = g + (u > 0 ? u : 0) + 450; printf "%.3f", t / 1000 }')"
}

for order in holder-first holder-last together; do
  n=$((${n:-0} + 1))
  say "case $n: remembered A (active at open, still Hyprland's focused window), release $order"
  close_with "$addr_a" "{\"target\":\"remembered\",\"address\":\"$addr_a\",\"workspace\":$ws_a}" "$order" 150 -1
  say "  chrome holding the keyboard at open: ${holder:-none}"
  type_to "case $n" "$cap_a" "ra$(printf '%s' "$order" | tr -cd 'a-z' | head -c 3)"
  [[ $mode == check ]] && outcome_is "case $n" "$id" focused "$addr_a"
done

say "case 4: window B (the other output), release holder first"
close_with "$addr_a" "{\"target\":\"window\",\"address\":\"$addr_b\"}" holder-first 150 -1
type_to "case 4" "$cap_b" "wbf"
[[ $mode == check ]] && outcome_is "case 4" "$id" focused "$addr_b"

say "case 5: window B, release holder first, the chromes unmap"
close_with "$addr_a" "{\"target\":\"window\",\"address\":\"$addr_b\"}" holder-first 120 60
type_to "case 5" "$cap_b" "wbu"
[[ $mode == check ]] && outcome_is "case 5" "$id" focused "$addr_b"

say "case 6a: the current Desktop ($ws_a, A active at open)"
close_with "$addr_a" "{\"target\":\"workspace\",\"workspace\":$ws_a}" holder-first 150 -1
type_to "case 6a" "$cap_a" "dcur"
[[ $mode == check ]] && outcome_is "case 6a" "$id" focused "$addr_a"

say "case 6b: B's Desktop ($ws_b, shown on $OUT_B) with A active at open"
close_with "$addr_a" "{\"target\":\"workspace\",\"workspace\":$ws_b}" holder-first 150 -1
type_to "case 6b" "$cap_b" "dother"
[[ $mode == check ]] && outcome_is "case 6b" "$id" focused "$addr_b"

say "case 7: another Desktop ($ws_c, not shown, C on it)"
close_with "$addr_a" "{\"target\":\"workspace\",\"workspace\":$ws_c}" holder-first 150 -1
shown_on=$(nestctl -j monitors | jq -r --argjson w "$ws_c" '[.[] | select(.activeWorkspace.id == $w) | .name][0] // ""')
if [[ $mode == check ]]; then [[ -n $shown_on ]]; check "case 7: Desktop $ws_c is shown" $? "on ${shown_on:-no output}"; fi
type_to "case 7" "$cap_c" "dnew"
[[ $mode == check ]] && outcome_is "case 7" "$id" focused "$addr_c"
focus_ws "$ws_b"
focus_ws "$ws_a"
[[ $(ws_of_output "$OUT_A") == "$ws_a" && $(ws_of_output "$OUT_B") == "$ws_b" ]] || { say "INVALID RUN: could not show Desktops $ws_a and $ws_b again"; exit 2; }

say "case 8: window E chosen, E closed during the close (fallback: the focused Desktop's front window, A)"
p=$(foot_capture gf-ovf-e "$cap_e"); pids+=("$p"); pid_e=$p; addr_e=$(address_of "$p")
move_to_ws "$addr_e" "$ws_a"
focus_window "$addr_d"
focus_window "$addr_a"
pointer "$OUT_A" abs 1900 120 sleep 80 # empty desktop on GF-REF
focus_window "$addr_e"
holder=$(open_chromes)
id=$((id + 1))
request "{\"target\":\"window\",\"address\":\"$addr_e\",\"id\":$id}"
kill "$pid_e" 2>/dev/null
sleep 0.4
release holder-first 150 -1
sleep 0.6
type_to "case 8" "$cap_a" "fgone"
[[ $mode == check ]] && outcome_is "case 8" "$id" fallback "$addr_a"

say "case 9: remembered D, D minimized during the close (fallback A, D never gets a key)"
park
focus_window "$addr_d"
holder=$(open_chromes)
id=$((id + 1))
request "{\"target\":\"remembered\",\"address\":\"$addr_d\",\"workspace\":$ws_a,\"id\":$id}"
# Grassfield's minimize without the animation (the shell's fallback path: the window parked on special:minimized), right
# after the request as a user would press the minimize shortcut while the Overview closes; D stays minimized afterwards.
nestctl dispatch "hl.dsp.window.move({ workspace = \"special:minimized\", follow = false, window = \"address:$addr_d\" })" >>"$log" 2>&1
release holder-first 150 -1
sleep 0.6
type_to "case 9" "$cap_a" "fmin"
[[ $mode == check ]] && outcome_is "case 9" "$id" fallback "$addr_a"
[[ $(ws_of_window "$addr_d") == special:minimized || $(nestctl -j clients | jq -r --arg a "$addr_d" '.[] | select(.address == $a) | .workspace.name') == special:minimized ]]
check "case 9: D is still minimized" $?

say "case 10: a press beside the remaining Exclusive chrome, on the other output's window, wins"
park
focus_window "$addr_a"
holder=$(open_chromes)
if [[ $holder == "$OUT_A" ]]; then press_win=$addr_a press_cap=$cap_a target_win=$addr_b; else press_win=$addr_b press_cap=$cap_b target_win=$addr_a; fi
id=$((id + 1))
request "{\"target\":\"window\",\"address\":\"$target_win\",\"id\":$id}"
release holder-first 900 -1 # the holder's chrome first; the other stays Exclusive for 0.9 s
sleep 0.15
read -r p_out p_x p_y < <(center_of "$press_win")
pointer "$p_out" abs "$p_x" "$p_y" sleep 60 click
sleep 1.1
say "  holder $holder, press on $press_win ($p_out $p_x,$p_y), named target $target_win"
type_to "case 10" "$press_cap" "pwin"
[[ $mode == check ]] && outcome_is "case 10" "$id" focused "$press_win"

say "case 11: a polkit-like dialog appears during the close and stays past the bound"
park
focus_window "$addr_a"
holder=$(open_chromes)
id=$((id + 1))
request "{\"target\":\"remembered\",\"address\":\"$addr_a\",\"workspace\":$ws_a,\"id\":$id}"
fx polkit "$OUT_A" >/dev/null
sleep 0.2
release holder-first 100 -1
sleep 0.4
type_to "case 11 (dialog up)" polkit "pqlk"
[[ $mode == check ]] && outcome_is "case 11" "$id" timeout
fx polkitRelease >/dev/null
sleep 0.8

say "case 12: a short polkit-like dialog during the close: nothing focused while it is up, A after it"
park
focus_window "$addr_b"
focus_window "$addr_a"
holder=$(open_chromes)
id=$((id + 1))
t_req=$(date +%s%3N)
request "{\"target\":\"remembered\",\"address\":\"$addr_a\",\"workspace\":$ws_a,\"id\":$id}"
fx polkit "$OUT_B" >/dev/null
release holder-first 60 -1
sleep 0.2
early=$(outcome_of "$id") # the chromes are released, the dialog is still up: nothing may be focused yet
t_rel=$(date +%s%3N)
fx polkitRelease >/dev/null
sleep 0.8
if [[ $mode == check ]]; then
  [[ -z $early ]]; check "case 12: no outcome while the dialog is up" $? "${early:-none}"
  say "  the dialog was released $((t_rel - t_req)) ms after the request (the bound is 1000 ms)"
fi
type_to "case 12" "$cap_a" "pshort"
[[ $mode == check ]] && outcome_is "case 12" "$id" focused "$addr_a"

if [[ $mode == check ]]; then
  say "case 13: invalid payloads and a flood"
  inv0=$(ovf_events | grep -c '"outcome":"invalid"')
  for payload in '{}' '{"target":"press","address":"0x1"}' '{"target":"window"}' '{"target":"workspace","workspace":-98}' 'not json' '{"target":"none","address":"0x1"}'; do
    request "$payload"
  done
  nestctl dispatch "hl.plugin.grassfield.overview_focus(42)" >>"$log" 2>&1
  sleep 0.6
  inv=$(($(ovf_events | grep -c '"outcome":"invalid"') - inv0))
  ((inv >= 1)); check "case 13: invalid payloads -> outcome invalid (coalesced)" $? "$inv invalid event(s), $(grep -ac 'overview focus: rejected' "$hyprlog") rejection log line(s)"
  ev0=$(ovf_events | wc -l)
  id=$((id + 1))
  nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview_focus then for i = 1, 300 do p.overview_focus([[{\"target\":\"window\",\"address\":\"$addr_a\",\"id\":$id}]]) end end end" >>"$log" 2>&1
  sleep 0.8
  ev=$(($(ovf_events | wc -l) - ev0))
  j=$(outcome_of "$id")
  ((ev <= 6)) && [[ $(jq -r '.outcome' <<<"$j") == focused ]]; check "case 13: 300 requests in one dispatch -> $ev event(s), one outcome" $? "$j"
  kill -0 "$socat_pid" 2>/dev/null && ! grep -q "overflowed event queue" "$hyprlog"; safe "case 13: the socket2 subscriber is still connected" $?

  say "case 14: plugin unload while a request waits"
  park
  focus_window "$addr_a"
  holder=$(open_chromes)
  id=$((id + 1))
  request "{\"target\":\"remembered\",\"address\":\"$addr_a\",\"workspace\":$ws_a,\"id\":$id}"
  sleep 0.2
  nestctl plugin unload "$plugin" >>"$log" 2>&1
  unload_rc=$?
  plugin_unloaded=1
  sleep 0.5
  j=$(outcome_of "$id")
  [[ $unload_rc == 0 && $(jq -r '.outcome' <<<"$j") == unavailable ]]; check "case 14: unload -> outcome unavailable" $? "rc $unload_rc, $j"
  kill -0 "$hypr_pid" 2>/dev/null && nestctl -j version >/dev/null; safe "case 14: Hyprland alive after the unload" $?
  release holder-first 100 -1
  sleep 0.6
  nestctl plugin load "$plugin" >>"$log" 2>&1
  load_rc=$?
  sleep 0.5
  has_feature overview-focus; feat=$?
  ((load_rc == 0 && feat == 0)) && plugin_unloaded=0
  [[ $load_rc == 0 && $feat == 0 ]]; check "case 14: reload advertises overview-focus" $? "$(features)"
  # A plugin load or unload reloads the configuration, whose monitor rules enable WAYLAND-1 again: the pair is set again.
  headless_up
  say "  outputs after the reload: $(mon_sizes)"
fi

say "case 15: the session lock arrives during the close (nothing typed)"
park
focus_window "$addr_a"
holder=$(open_chromes)
id=$((id + 1))
request "{\"target\":\"remembered\",\"address\":\"$addr_a\",\"workspace\":$ws_a,\"id\":$id}"
ev_lock=$(grep -ac "" "$events")
WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig GRASSFIELD_FOREIGN_LOCKER=1 DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
  setsid "$root/scripts/dev/isolated.sh" --name overview-focus-locker qs -p "$foreign" --no-color >"$run/locker.log" 2>&1 </dev/null &
locker_pid=$!
locked=""
for i in $(seq 1 60); do
  locked=$(foreign_ipc status)
  [[ $locked == "locked secure" ]] && break
  sleep 0.1
done
release holder-first 100 -1
sleep 0.8
focus_events=$(tail -n +"$((ev_lock + 1))" "$events" | grep -acE "^[0-9]+ activewindowv2>>[0-9a-f]+$" || true)
[[ $locked == "locked secure" ]]; check "case 15: the foreign locker holds the session lock" $? "${locked:-no answer}"
((focus_events == 0)); safe "case 15: no window focused while locked" $? "$focus_events activewindowv2 event(s) naming a window"
[[ $mode == check ]] && outcome_is "case 15" "$id" refused
foreign_ipc unlock >/dev/null
for i in $(seq 1 30); do kill -0 "$locker_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$locker_pid" 2>/dev/null && kill "$locker_pid" 2>/dev/null
locker_pid=""
sleep 0.5

# ---- health ----
kill -0 "$hypr_pid" 2>/dev/null; safe "health: nested Hyprland alive" $?
end_sizes=$(mon_sizes)
[[ $end_sizes == "$start_sizes" ]]; safe "health: outputs unchanged during the run" $? "$end_sizes"
refusals=$(grep -ac "ignoring, exclusive LS present" "$hyprlog" 2>/dev/null)
say "Hyprland log: $refusals 'ignoring, exclusive LS present' line(s) in this session; plugin lines: $(grep -ac '\[grassfield\] overview focus' "$hyprlog" 2>/dev/null)"
grep -a '\[grassfield\] overview focus' "$hyprlog" 2>/dev/null | tail -n 40 >"$run/plugin-lines.log"
i915=$(journalctl -k --since "-15 min" 2>/dev/null | grep -ci "fence expiration\|gpu hang" || true)
say "kernel: ${i915:-0} i915 fence timeout / GPU hang line(s) in the last 15 min"

if [[ $mode == check ]]; then
  if ((fail)); then say "FAIL ($passed/$total checks)"; exit 1; fi
  say "PASS ($passed/$total checks)"
  exit 0
fi
say "baseline: $passed/$total checks pass; safety $([[ $safety_fail == 0 ]] && echo PASS || echo FAIL)"
((safety_fail)) && exit 1
exit 0
