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
# Window placement is the compositor's business (GF-006): every window's rectangle is read from `hyprctl -j clients`
# (tests/compositor/window_geometry.sh), C's REAL titlebar and close button are aimed at, and the click on B goes to a
# point of B's real rectangle that C's real rectangle does not cover. Output: IC_OUTPUT (default GF-REF).
# A drag that did not move C (the aim missed) is a harness error, never a pass.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error or harness error (the gesture could not be driven).
# Log: .dev/input-consistency/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
rounds=${1:-3}
[[ $rounds =~ ^[1-9][0-9]*$ ]] || { echo "usage: input_consistency.sh [rounds]" >&2; exit 2; }

out=${IC_OUTPUT:-GF-REF}

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh): a stale record
# may name another worktree's session.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
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
# Capture files of earlier runs (possibly with more rounds) must not be read as this run's.
rm -f "$work"/*.cap
log=$work/run-$(date +%Y%m%d-%H%M%S).log
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

# A foot window that reports button presses and releases (SGR) into <capture>. The tty is put in raw mode
# so cat gets every byte at once (no line buffering).
foot_capture() { # <capture file> -> prints the foot PID
  : >"$1"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot -e sh -c \
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

# shellcheck source=window_geometry.sh
. "$root/tests/compositor/window_geometry.sh"
gf_geom_init || { echo "input_consistency: output $out not listed by hyprctl monitors" >&2; exit 2; }
mid_x=$((out_w / 2))
harness_error() { say "input_consistency: HARNESS ERROR: $*"; say "input_consistency: log $log"; exit 2; }
# A click point inside B's rectangle (its content, 40 px from the edges) that C's rectangle, with its titlebar, does not
# cover; sets b_x b_y. <B geometry> <C geometry>
pick_b_point() {
  local bx by bw bh cx cy cw ch gx gy
  read -r bx by bw bh <<<"$1"
  read -r cx cy cw ch <<<"$2"
  for ((gy = by + 60; gy < by + bh - 40; gy += 40)); do
    for ((gx = bx + 40; gx < bx + bw - 40; gx += 60)); do
      if ((gx < cx - 10 || gx > cx + cw + 10 || gy < cy - GF_TB_HEIGHT - 10 || gy > cy + ch + 10)) \
        && ((gx > 0 && gx < out_w && gy > 40 && gy < out_h - 120)); then
        b_x=$gx b_y=$gy
        return 0
      fi
    done
  done
  return 1
}

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

b_geom=$(gf_window_geom "$b_pid" 4000) || harness_error "no window of B (pid $b_pid) found on $out"
read -r b0x b0y b0w b0h <<<"$b_geom"
b_x=$((b0x + b0w / 4)) b_y=$((b0y + b0h / 2)) # setup click: B alone is on screen
say "  B: ${b0w}x${b0h} at $b0x,$b0y"

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

  # drag: grab C's REAL titlebar (on top of B) and move it far, fast; release. C ends on the right of the output when
  # that is far enough from where it opened, else on the left.
  c_geom=$(gf_window_geom "$c_pid" 4000) || harness_error "round $r: no window of C (pid $c_pid) found on $out"
  read -r c0x c0y c0w c0h <<<"$c_geom"
  read -r bar_x bar_y <<<"$(gf_bar_point "$c0x" "$c0y" "$c0w" "$c0h")"
  gx=$((bar_x + (r % 3) * 20 - 20))
  nx=$((out_w - c0w - 40))
  ((nx - c0x < 150 && nx - c0x > -150)) && nx=20
  dx=$((nx - c0x))
  dy=$((out_h / 3 - c0y))
  ((dy < 100 && dy > -100)) && dy=200
  ((c0y + dy + c0h > out_h - 150)) && dy=$((out_h - 150 - c0h - c0y))
  pointer abs "$gx" "$bar_y" sleep 60 down drag $((gx + dx)) $((bar_y + dy)) up
  sleep 0.4
  c_geom2=$(gf_window_geom "$c_pid" 2000) || harness_error "round $r: C disappeared after the drag"
  if ! gf_geom_moved "$c_geom" "$c_geom2"; then
    harness_error "round $r: the drag did not move C (aimed at its titlebar $gx,$bar_y; C at ${c_geom% *} before, ${c_geom2% *} after): the gesture was not driven"
  fi
  read -r c1x c1y c1w c1h <<<"$c_geom2"
  pick_b_point "$b_geom" "$c_geom2" || harness_error "round $r: no point of B is clear of C (C at $c_geom2, B at $b_geom)"
  check_click_on_b "drag" "$c_cap"

  # cancel: press C's real close button (C has moved), move away across C's content, release there: must not close C.
  read -r cx cy <<<"$(gf_button_point close "$c1x" "$c1y" "$c1w" "$c1h")"
  ex=$((cx + 200))
  ((ex > out_w - 20)) && ex=$((cx - 200))
  ey=$((cy + 160))
  ((ey > out_h - 120)) && ey=$((cy - 60))
  pointer abs "$cx" "$cy" sleep 60 down drag "$ex" "$ey" up
  sleep 0.4
  if ! kill -0 "$c_pid" 2>/dev/null; then
    say "  cancel: FAIL (the close button press, moved away, closed C)"
    fail=1
  fi
  # C may have moved again; B's click spot is chosen against where C is now.
  if c_geom3=$(gf_window_geom "$c_pid" 1000); then pick_b_point "$b_geom" "$c_geom3" || pick_b_point "$b_geom" "$c_geom2" || true; fi
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
