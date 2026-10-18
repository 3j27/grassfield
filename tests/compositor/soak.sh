#!/usr/bin/env bash
# C1 soak (master-prompt §10): scripted window churn against the NESTED dev compositor only.
#
# Usage: tests/compositor/soak.sh [duration_s] [stages]  (default 3600; `stages`: the same churn with Stages on)
# Needs a running nested instance with grassfield-compositor loaded (scripts/dev/nested-up.sh).
# Two long-lived foot windows stay open for the whole run. Each round: opens a short-lived foot
# (`foot -e true`), opens a new churn window (the oldest of 4 is killed first), and drives the titlebar
# of the new window with the virtual pointer (scripts/dev/pointer.sh): drags (some abandoned mid-drag,
# so the pointer device disappears while a button is held), double-click zoom, zoom button, close
# button, press-move-away cancel, and (when the plugin advertises "minimize" and grassfield-shell runs)
# minimize button + restore through a click on the Dock tile (geometry as in tests/compositor/minimize.sh).
# The double-click rounds expect Settings windows.titlebarDoubleClick = zoom (the default).
# The Dock tile is clicked only after the window was seen moving to special:minimized (socket2 movewindowv2), so the
# click always lands on that (foot) window's minimized tile, never on another Dock tile; the Dock geometry used and one
# capture of the Dock at the first minimize are logged.
# With `stages`: the Stages flag on, the strip stand-in tests/compositor/stages-fixture mapped on SOAK_OUTPUT and op "on"
# sent (verbs through scripts/nestctl); every 5th round one long-lived window is moved into a strip stage of its own, every
# 7th round the stage in tile 0 is activated (a swap), so that windows keep entering and leaving the strip (blocked and
# transformed) while the churn goes on. Every window is a foot with the default app id (no extra Dock tile).
# New windows open centered on the output, so their titlebar is at a known place:
#   SOAK_OUTPUT (GF-REF), SOAK_WIN_W (700, foot's default width), SOAK_BAR_Y (250, titlebar middle).
# At the end: PASS (exit 0) when the nested Hyprland is still alive, `coredumpctl list Hyprland`
# shows no dump of its PID since the start (dumps of other Hyprland instances are listed, not counted),
# and the nested log has no grassfield exception; FAIL (exit 1) otherwise; 2 = usage or environment
# error. Log: .dev/soak-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
duration=3600
stages_mode=0
for arg in "$@"; do
  case $arg in
    stages) stages_mode=1 ;;
    *) [[ $arg =~ ^[0-9]+$ ]] || { echo "usage: soak.sh [duration_s] [stages]" >&2; exit 2; }; duration=$arg ;;
  esac
done

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
foot_bg() { WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot "$@" >/dev/null 2>&1 </dev/null & echo $!; }

# Output size, for targets that stay clear of the menu bar (top) and the Dock (bottom).
read -r out_w out_h < <(timeout 20 "$root/scripts/dev/pointer.sh" outputs 2>/dev/null \
  | awk -v o="$out" '$1 == o { split($3, s, "x"); print s[1], s[2] }')
[[ -n ${out_w:-} && -n ${out_h:-} ]] || { echo "soak: output $out not found" >&2; exit 2; }

left=$(((out_w - win_w) / 2))
mid_x=$((out_w / 2))
close_x=$((left + 18))
min_x=$((left + 38))
zoom_x=$((left + 58))

# Minimize rounds: plugin feature (read-only `hyprctl grassfield`) and a running shell (Dock, minimize-request).
minimize_rounds=0
shell_pid=$(cat "$dev/shell.pid" 2>/dev/null || true)
if HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -e '.features | index("minimize")' >/dev/null 2>&1 \
  && [[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null; then
  minimize_rounds=1
  token() { sed -n "s/.*readonly property int $1: \([0-9]*\).*/\1/p" "$root/ui/Grassfield/Ui/Tokens.qml" | head -n 1; }
  icon=$(token dockIconSize)
  dspacing=$(token dockSpacing)
  dpadding=$(token dockPadding)
  sep_w=$((2 * dspacing + $(token dockSeparatorWidth)))
  tile_y=$((out_h - $(token dockBottomMargin) - (icon + 2 * dpadding + $(token dockIndicatorSize) + dspacing) + dpadding + icon / 2))
  config=$dev/config/grassfield.json
  [[ -f $config ]] || config=$root/config/defaults/grassfield.json
  apps=0
  while read -r id; do
    for d in "${XDG_DATA_HOME:-$HOME/.local/share}" /usr/local/share /usr/share; do
      if [[ -f $d/applications/$id.desktop ]]; then apps=$((apps + 1)); break; fi
    done
  done < <(jq -r --slurpfile d "$root/config/defaults/grassfield.json" '(.dock.pinned // $d[0].dock.pinned)[]' "$config")
  n=$((apps + 2)) # apps, one minimized tile, the Trash
  restore_x=$(((out_w - (n * icon + sep_w + n * dspacing)) / 2 + apps * (icon + dspacing) + sep_w + dspacing + icon / 2))
  pinned_ids=$(jq -r --slurpfile d "$root/config/defaults/grassfield.json" '(.dock.pinned // $d[0].dock.pinned) | join(",")' "$config")
fi
rand_x() { echo $((100 + RANDOM % (out_w - 200))); }
rand_y() { echo $((80 + RANDOM % (out_h - 280))); }

pool=()      # churn windows, oldest first
resident=() # long-lived windows (whole run)
spawned=0 short=0 drags=0 abandoned=0 zooms=0 closes=0 cancels=0 minimizes=0 skipped=0 round=0
st_moves=0 st_swaps=0
fixture_pid=""
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; } # verbs of the plugin (Stages mode only)
cleanup() {
  if ((stages_mode)); then
    nestctl dispatch 'hl.plugin.grassfield.stages([[{"op":"off","durationMs":0}]])' >/dev/null 2>&1
    nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
    [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  fi
  for p in "${pool[@]}" "${resident[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n ${events_pid:-} ]] && kill "$events_pid" 2>/dev/null
}
trap cleanup EXIT

# Minimize accounting: "minimized" events (socket2, read-only, socat) and the plugin's log line for a
# rejected Dock rectangle (the window is then hidden without animation).
events=$dev/soak-events-$start_epoch.log
events_pid=
rejected_before=0
if (( minimize_rounds || stages_mode )); then
  command -v socat >/dev/null || { echo "soak: socat is needed to read the plugin's events" >&2; exit 2; }
  [[ -r $hyprlog ]] && rejected_before=$(grep -c 'minimize [0-9a-f]*: no valid Dock rectangle' "$hyprlog")
  socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT </dev/null >"$events" 2>>"$log" &
  events_pid=$!
fi
moves_to_minimized() { grep -cE '^movewindowv2>>[0-9a-f]+,[^,]*,special:minimized$' "$events" 2>/dev/null; }
st_last() { grep -a 'grassfield>>{"v":"gfc/1","type":"stages"' "$events" | tail -n 1 | sed 's/^grassfield>>//'; }
addr_of_pid() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p)][0].address // ""'; }
dock_shot=""

if ((stages_mode)); then
  HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -e '.features | index("stages-available")' >/dev/null 2>&1 \
    || { echo "soak: the loaded plugin does not advertise \"stages-available\"" >&2; exit 2; }
  read -r mon_x mon_y < <(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y)"')
  strip_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '{x: $x, y: ($y + 60), w: 220, h: 860}')
  tiles_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '[range(0; 4) as $i | {x: ($x + 16), y: ($y + 100 + $i * 190), w: 188, h: 160}]')
  fixlog=$dev/soak-stages-fixture-$start_epoch.log
  GF_STAGES_OUTPUT=$out GF_STAGES_STRIP=$strip_json GF_STAGES_TILES=$tiles_json WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    setsid "$root/scripts/dev/isolated.sh" --name stages-fixture qs -p "$root/tests/compositor/stages-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  for _ in $(seq 1 50); do grep -q "\[stages-fixture\] output $out found" "$fixlog" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
  grep -q "\[stages-fixture\] output $out found" "$fixlog" || { echo "soak: the Stages strip stand-in did not start ($fixlog)" >&2; exit 2; }
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "true")' >/dev/null 2>&1
  nestctl dispatch "hl.plugin.grassfield.stages([[$(jq -nc --arg o "$out" --argjson t "$tiles_json" '{op: "on", durationMs: 350, strips: [{monitor: $o, tiles: $t}]}')]])" >/dev/null 2>&1
  sleep 0.5
  [[ $(st_last | jq -r '.on') == true ]] || { echo "soak: Stages did not turn on: $(st_last)" >&2; exit 2; }
fi

say "soak: start $start_human, duration ${duration}s, nested pid $hypr_pid, instance $sig, output $out ${out_w}x${out_h}"
say "soak: Hyprland RSS at start: $(rss_kb) kB"
((minimize_rounds)) && say "soak: Dock: $apps pinned app tile(s) with a desktop entry (pinned: ${pinned_ids:-?}); the minimized foot tile is clicked at ($restore_x,$tile_y) only after its window moved to special:minimized"
((stages_mode)) && say "soak: Stages on (strip stand-in on $out, 4 tiles); resident windows moved into strip stages every 5th round, tile 0 activated every 7th"

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

  case $((round % (7 + minimize_rounds))) in
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
    7) # minimize the newest window with its button, restore it from its Dock tile (while it may still animate). The
      # tile is clicked only once the window moved to special:minimized: otherwise there is no minimized tile there.
      m0=$(moves_to_minimized)
      pointer abs "$min_x" "$bar_y" sleep 50 click
      moved=0
      for _ in $(seq 1 30); do
        (($(moves_to_minimized) > m0)) && { moved=1; break; }
        sleep 0.05
      done
      if ((moved)); then
        sleep "0.$((150 + RANDOM % 400))"
        if [[ -z $dock_shot ]]; then
          dock_shot=$dev/soak-dock-$start_epoch.png
          WAYLAND_DISPLAY=$sock grim -l 0 -o "$out" "$dock_shot" 2>>"$log" && say "soak: Dock captured at the first minimize: $dock_shot (tile clicked at $restore_x,$tile_y)"
        fi
        pointer abs "$restore_x" "$tile_y" sleep 50 click sleep 300
        minimizes=$((minimizes + 1))
      else
        skipped=$((skipped + 1)) # the newest window was not where its button was expected (e.g. a resident covered it)
      fi ;;
  esac

  if ((stages_mode)); then
    if ((round % 5 == 0)) && ((${#resident[@]} > 0)); then
      ra=$(addr_of_pid "${resident[$((round / 5 % ${#resident[@]}))]}")
      [[ -n $ra ]] && nestctl dispatch "hl.plugin.grassfield.stages([[{\"op\":\"move\",\"address\":\"$ra\",\"stage\":\"new\"}]])" >/dev/null 2>&1 && st_moves=$((st_moves + 1))
    fi
    if ((round % 7 == 3)); then
      s0=$(st_last | jq -r '[.monitors[0].stages[]? | select(.slot == 0) | .id][0] // 0')
      ((s0 > 0)) && nestctl dispatch "hl.plugin.grassfield.stages([[{\"op\":\"activate\",\"stage\":$s0}]])" >/dev/null 2>&1 && st_swaps=$((st_swaps + 1))
    fi
  fi

  if (( round % 100 == 0 )); then
    say "soak: round $round, $(( $(date +%s) - start_epoch ))s, short $short, churn $spawned, resident ${#resident[@]}, drags $drags, abandoned $abandoned, zoom pairs $zooms, cancels $cancels, closes $closes, minimize pairs $minimizes (skipped $skipped), stages moves $st_moves swaps $st_swaps, RSS $(rss_kb) kB"
  fi
  sleep 0.3
done

elapsed=$(( $(date +%s) - start_epoch ))
say "soak: done after ${elapsed}s, $round rounds: short $short, churn $spawned, drags $drags, abandoned $abandoned, zoom pairs $zooms, cancels $cancels, closes $closes, minimize pairs $minimizes (skipped, no move seen: $skipped)"
((stages_mode)) && say "soak: Stages: $st_moves move-to-new-stage and $st_swaps activate requests, $(grep -ac 'grassfield>>{"v":"gfc/1","type":"stages"' "$events") stages events, still on: $(st_last | jq -r '.on')"

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
# Other Hyprland instances (e.g. other worktrees' nested sessions) may dump too: only this instance's
# PID fails the run; the others are listed with their command line.
pids=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null)
for p in $pids; do
  if [[ $p == "$hypr_pid" ]]; then
    say "check: FAIL core dump of the nested Hyprland (pid $p)"
    fail=1
  else
    say "check: core dump of another Hyprland (pid $p, not this nested instance): $(coredumpctl --no-pager info "$p" 2>/dev/null | sed -n 's/^ *Command Line: //p' | head -n 1)"
  fi
done

if [[ -r $hyprlog ]]; then
  exceptions=$(grep -c '\[grassfield\].*exception' "$hyprlog")
  stray=$(grep -c 'sendButton release on a non-pressed button' "$hyprlog")
  say "check: grassfield exceptions in nested log: $exceptions; seat 'release on a non-pressed button' warnings: $stray"
  (( exceptions == 0 )) || fail=1
else
  say "check: nested log $hyprlog not readable (exceptions NOT checked)"
fi

if (( minimize_rounds )); then
  total=$(grep -c 'grassfield>>{"v":"gfc/1","type":"minimized"' "$events" 2>/dev/null)
  rejected=$(( $(grep -c 'minimize [0-9a-f]*: no valid Dock rectangle' "$hyprlog" 2>/dev/null) - rejected_before ))
  animated=$((total - rejected))
  say "check: minimizes: $total total, $animated animated, $rejected rejected (no valid Dock rectangle)"
  if (( animated <= 0 )); then
    say "check: FAIL no minimize animated although the plugin advertises minimize"
    fail=1
  fi
fi

if (( fail == 0 )); then say "soak: PASS"; else say "soak: FAIL"; fi
say "soak: log $log"
exit "$fail"
