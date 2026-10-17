#!/usr/bin/env bash
# Regression scenario (FR13, counter-review finding): a titlebar gesture must leave Hyprland's held-button
# state consistent, so that the next click on another window reaches that window.
#
# Usage: tests/compositor/input_consistency.sh [rounds]          (default 3)
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded. Pointer input goes through
# scripts/dev/pointer.sh, clients get the nested socket only.
#
# Two foot windows report mouse buttons (xterm modes 1000 + 1006, SGR: ESC[<0;col;rowM press, ...m release)
# into capture files under .dev/input-consistency/:
#   B  opened first, stays centered on the output for the whole run;
#   C  opened on top of B (same centered place), one new C per round.
# Each round, on C:
#   drag    fast titlebar drag down-right: the bar lags the pointer, which crosses C's content; release;
#   cancel  press C's close button, move away across C's content, release there (must not close C);
# and after each of them one click inside B, at a spot C does not cover. That click must reach B's capture
# file, and C's capture file must never receive a button event (nothing ever clicks inside C).
# Before the fix, the release of the titlebar press was cancelled on the event bus, Hyprland kept the
# button as held and kept pointer focus on C: B's click was delivered to C at its edge.
#
# Window placement: new windows open centered on SOAK_OUTPUT-style defaults (same as soak.sh):
#   IC_OUTPUT (GF-REF), IC_WIN_W (700, foot's default width), IC_BAR_Y (250, titlebar middle).
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/input-consistency/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
rounds=${1:-3}
[[ $rounds =~ ^[1-9][0-9]*$ ]] || { echo "usage: input_consistency.sh [rounds]" >&2; exit 2; }

out=${IC_OUTPUT:-GF-REF}
win_w=${IC_WIN_W:-700}
bar_y=${IC_BAR_Y:-250}

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "input_consistency: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "input_consistency: refusing: recorded nested instance is the main session" >&2
  exit 2
fi

work=$dev/input-consistency
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

# A foot window that reports button presses and releases (SGR) into <capture>. The tty is put in raw mode
# so cat gets every byte at once (no line buffering).
foot_capture() { # <capture file> -> prints the foot PID
  : >"$1"
  WAYLAND_DISPLAY=$sock setsid foot -e sh -c \
    'stty raw -echo; printf "\033[?1000h\033[?1006h"; exec cat -v >"$0"' "$1" \
    >/dev/null 2>&1 </dev/null &
  echo $!
}

# SGR mouse events (cat -v shows ESC as ^[) in a capture file, from byte <offset> on.
sgr_events() { # <file> <offset>
  tail -c +"$(($2 + 1))" "$1" 2>/dev/null | grep -aoE '\[<[0-9]+;[0-9]+;[0-9]+[Mm]' | tr '\n' ' '
}
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }

read -r out_w out_h < <(timeout 20 "$root/scripts/dev/pointer.sh" outputs 2>/dev/null \
  | awk -v o="$out" '$1 == o { split($3, s, "x"); print s[1], s[2] }')
[[ -n ${out_w:-} && -n ${out_h:-} ]] || { echo "input_consistency: output $out not found" >&2; exit 2; }

left=$(((out_w - win_w) / 2))
mid_x=$((out_w / 2))
# Inside B (centered), left part of its content: C never covers it after its first drag.
b_x=$((left + 100))
b_y=$((bar_y + 150))
# C's drag: its titlebar grab point moves by (dx, dy), down-right, away from (b_x, b_y).
dx=$(((out_w - win_w) / 2 - 60))
dy=$((out_h / 3))

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

say "input_consistency: nested pid $hypr_pid, instance $sig, output $out ${out_w}x${out_h}, $rounds rounds"
seat_warnings() { local n; n=$(grep -c 'sendButton release on a non-pressed button' "$hyprlog" 2>/dev/null); echo "${n:-0}"; }
seat_before=$(seat_warnings)

# Windows open on the output under the pointer.
pointer abs "$mid_x" $((out_h - 150)) sleep 50

b_cap=$work/B.cap
b_pid=$(foot_capture "$b_cap")
pids+=("$b_pid")
sleep 1.2

fail=0
# One click inside B; it must reach B (and not C).
check_click_on_b() { # <label> <C capture>
  local label=$1 c_cap=$2 b_off c_off b_new c_new
  b_off=$(size_of "$b_cap")
  c_off=$(size_of "$c_cap")
  pointer abs "$b_x" "$b_y" sleep 150 abs $((b_x + 3)) $((b_y + 2)) sleep 150 click sleep 250
  b_new=$(sgr_events "$b_cap" "$b_off")
  c_new=$(sgr_events "$c_cap" "$c_off")
  if [[ $b_new == *M* && -z $c_new ]]; then
    say "  $label: OK   (B got: ${b_new% })"
  else
    say "  $label: FAIL (B got: '${b_new% }', C got: '${c_new% }')"
    fail=1
  fi
}

# Sanity: B receives a plain click before any titlebar gesture, otherwise the setup is broken.
off=$(size_of "$b_cap")
pointer abs "$b_x" "$b_y" sleep 150 click sleep 250
if [[ $(sgr_events "$b_cap" "$off") != *M* ]]; then
  say "input_consistency: setup error: B did not report a plain click (capture $b_cap)"
  exit 2
fi
say "  setup: B reports clicks"

for ((r = 1; r <= rounds; r++)); do
  say "round $r"
  c_cap=$work/C$r.cap
  pointer abs "$mid_x" $((out_h - 150)) sleep 50
  c_pid=$(foot_capture "$c_cap")
  pids+=("$c_pid")
  sleep 1.2

  # drag: grab C's titlebar (centered, on top of B) and move it down-right fast; release.
  gx=$((mid_x + (r % 3) * 20 - 20))
  pointer abs "$gx" "$bar_y" sleep 60 down drag $((gx + dx)) $((bar_y + dy)) up
  sleep 0.4
  check_click_on_b "drag" "$c_cap"

  # cancel: press C's close button (now moved by dx, dy), move away across C's content, release there.
  cx=$((left + 18 + dx))
  cy=$((bar_y + dy))
  pointer abs "$cx" "$cy" sleep 60 down drag $((cx + 200)) $((cy + 160)) up
  sleep 0.4
  if ! kill -0 "$c_pid" 2>/dev/null; then
    say "  cancel: FAIL (the close button press, moved away, closed C)"
    fail=1
  fi
  check_click_on_b "cancel" "$c_cap"

  kill "$c_pid" 2>/dev/null
  sleep 0.6
done

c_all=$(for f in "$work"/C*.cap; do sgr_events "$f" 0; done)
seat_after=$(seat_warnings)
say "check: button events received by the C windows over the run: '${c_all% }'"
say "check: seat warnings 'release on a non-pressed button' during the run: $((seat_after - seat_before))"
[[ -z ${c_all// /} ]] || fail=1
if ! kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi

if ((fail == 0)); then say "input_consistency: PASS"; else say "input_consistency: FAIL"; fi
say "input_consistency: log $log"
exit "$fail"
