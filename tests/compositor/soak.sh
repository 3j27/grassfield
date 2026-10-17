#!/usr/bin/env bash
# C1 soak (master-prompt §10): scripted window churn against the NESTED dev compositor only.
#
# Usage: tests/compositor/soak.sh [duration_s]          (default 3600)
# Needs a running nested instance with grassfield-compositor loaded (scripts/dev/nested-up.sh).
# Two long-lived foot windows stay open for the whole run. Each round: opens a short-lived foot
# (`foot -e true`), opens a new churn window (the oldest of 4 is killed first), and drives the titlebar
# of the new window with the virtual pointer (scripts/dev/pointer.sh): drags (some abandoned mid-drag,
# so the pointer device disappears while a button is held), double-click zoom, zoom button, close
# button, press-move-away cancel.
# New windows open centered on the output, so their titlebar is at a known place:
#   SOAK_OUTPUT (GF-REF), SOAK_WIN_W (700, foot's default width), SOAK_BAR_Y (250, titlebar middle).
# At the end: PASS (exit 0) when the nested Hyprland is still alive, `coredumpctl list Hyprland`
# shows no dump since the start, and the nested log has no grassfield exception; FAIL (exit 1)
# otherwise; 2 = usage or environment error. Log: .dev/soak-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
duration=${1:-3600}
[[ $duration =~ ^[0-9]+$ ]] || { echo "usage: soak.sh [duration_s]" >&2; exit 2; }

out=${SOAK_OUTPUT:-GF-REF}
win_w=${SOAK_WIN_W:-700}
bar_y=${SOAK_BAR_Y:-250}
pool_max=4

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "soak: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "soak: refusing: recorded nested instance is the main session" >&2
  exit 2
fi

hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
log=$dev/soak-$(date +%Y%m%d-%H%M%S).log
start_epoch=$(date +%s)
start_human=$(date '+%Y-%m-%d %H:%M:%S')
end_epoch=$((start_epoch + duration))

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
rss_kb() { awk '/^VmRSS:/ {print $2}' "/proc/$hypr_pid/status" 2>/dev/null || echo "?"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
foot_bg() { WAYLAND_DISPLAY=$sock setsid foot "$@" >/dev/null 2>&1 </dev/null & echo $!; }

# Output size, for targets that stay clear of the menu bar (top) and the Dock (bottom).
read -r out_w out_h < <(timeout 20 "$root/scripts/dev/pointer.sh" outputs 2>/dev/null \
  | awk -v o="$out" '$1 == o { split($3, s, "x"); print s[1], s[2] }')
[[ -n ${out_w:-} && -n ${out_h:-} ]] || { echo "soak: output $out not found" >&2; exit 2; }

left=$(((out_w - win_w) / 2))
mid_x=$((out_w / 2))
close_x=$((left + 18))
zoom_x=$((left + 58))
rand_x() { echo $((100 + RANDOM % (out_w - 200))); }
rand_y() { echo $((80 + RANDOM % (out_h - 280))); }

pool=()      # churn windows, oldest first
resident=() # long-lived windows (whole run)
spawned=0 short=0 drags=0 abandoned=0 zooms=0 closes=0 cancels=0 round=0
cleanup() {
  for p in "${pool[@]}" "${resident[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

say "soak: start $start_human, duration ${duration}s, nested pid $hypr_pid, instance $sig, output $out ${out_w}x${out_h}"
say "soak: Hyprland RSS at start: $(rss_kb) kB"

while (( $(date +%s) < end_epoch )); do
  round=$((round + 1))

  if ! kill -0 "$hypr_pid" 2>/dev/null; then
    say "soak: nested Hyprland (pid $hypr_pid) died at round $round"
    break
  fi

  # Long-lived windows: two of them for the whole run (respawned if one was closed by a click).
  alive=()
  for p in "${resident[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
  resident=("${alive[@]}")
  while (( ${#resident[@]} < 2 )); do
    resident+=("$(foot_bg -e sleep "$duration")")
    sleep 0.6
    pointer abs "$mid_x" "$bar_y" sleep 50 down drag "$(rand_x)" "$(rand_y)" sleep 30 up # out of the way
  done

  # Short-lived window: maps and unmaps at once.
  foot_bg -e true >/dev/null
  short=$((short + 1))

  # Churn window: a new one each round, centered, so its titlebar is at (mid_x, bar_y). The oldest of
  # pool_max is killed first (abrupt client disconnect); others end through the close button.
  alive=()
  for p in "${pool[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
  pool=("${alive[@]}")
  if (( ${#pool[@]} >= pool_max )); then
    kill "${pool[0]}" 2>/dev/null
    pool=("${pool[@]:1}")
  fi
  pool+=("$(foot_bg -e sleep 600)")
  spawned=$((spawned + 1))
  sleep 0.7 # let it map

  case $((round % 7)) in
    0 | 1) # drag the newest window somewhere and release
      pointer abs $((mid_x + RANDOM % 80 - 40)) "$bar_y" sleep 50 down drag "$(rand_x)" "$(rand_y)" sleep 30 up
      drags=$((drags + 1)) ;;
    2) # abandon a drag: the virtual pointer goes away with the button held; then click elsewhere
      pointer abs "$mid_x" "$bar_y" sleep 50 down drag "$(rand_x)" "$(rand_y)"
      pointer abs "$(rand_x)" "$(rand_y)" sleep 50 click
      abandoned=$((abandoned + 1)) ;;
    3) # double-click zoom, twice (maximize, restore)
      pointer abs "$mid_x" "$bar_y" sleep 50 click sleep 60 click sleep 500
      pointer abs "$mid_x" 39 sleep 50 click sleep 60 click sleep 300
      zooms=$((zooms + 1)) ;;
    4) # zoom button, twice
      pointer abs "$zoom_x" "$bar_y" sleep 50 click sleep 500
      pointer abs 58 39 sleep 50 click sleep 300
      zooms=$((zooms + 1)) ;;
    5) # press the close button, move away, release: must not close
      pointer abs "$close_x" "$bar_y" sleep 50 down drag "$(rand_x)" "$(rand_y)" sleep 30 up
      cancels=$((cancels + 1)) ;;
    6) # close the newest window with its close button
      pointer abs "$close_x" "$bar_y" sleep 50 click
      closes=$((closes + 1)) ;;
  esac

  if (( round % 100 == 0 )); then
    say "soak: round $round, $(( $(date +%s) - start_epoch ))s, short $short, churn $spawned, resident ${#resident[@]}, drags $drags, abandoned $abandoned, zoom pairs $zooms, cancels $cancels, closes $closes, RSS $(rss_kb) kB"
  fi
  sleep 0.3
done

elapsed=$(( $(date +%s) - start_epoch ))
say "soak: done after ${elapsed}s, $round rounds: short $short, churn $spawned, drags $drags, abandoned $abandoned, zoom pairs $zooms, cancels $cancels, closes $closes"

fail=0
if kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: nested Hyprland pid $hypr_pid alive, RSS $(rss_kb) kB"
else
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi

dumps=$(coredumpctl --no-pager list Hyprland --since "$start_human" 2>&1)
say "check: coredumpctl --no-pager list Hyprland --since '$start_human':"
printf '%s\n' "$dumps" | tee -a "$log"
if ! grep -q 'No coredumps found' <<<"$dumps"; then
  say "check: FAIL new Hyprland core dump(s)"
  fail=1
fi

if [[ -r $hyprlog ]]; then
  exceptions=$(grep -c '\[grassfield\].*exception' "$hyprlog")
  stray=$(grep -c 'sendButton release on a non-pressed button' "$hyprlog")
  say "check: grassfield exceptions in nested log: $exceptions; seat 'release on a non-pressed button' warnings: $stray"
  (( exceptions == 0 )) || fail=1
else
  say "check: nested log $hyprlog not readable (exceptions NOT checked)"
fi

if (( fail == 0 )); then say "soak: PASS"; else say "soak: FAIL"; fi
say "soak: log $log"
exit "$fail"
