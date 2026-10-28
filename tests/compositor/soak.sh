#!/usr/bin/env bash
# C1 soak (master-prompt §10): scripted window churn against the NESTED dev compositor only.
#
# Usage: tests/compositor/soak.sh [duration_s] [stages]  (default 3600; `stages`: the same churn with Stages on)
# Needs a running nested instance with grassfield-compositor loaded (scripts/dev/nested-up.sh).
# Two long-lived foot windows stay open for the whole run. Each round: opens a short-lived foot
# (`foot -e true`), opens a new churn window (the oldest of 4 is killed first), and drives the titlebar
# of the new window with the virtual pointer (scripts/dev/pointer.sh): drags (some abandoned mid-drag,
# so the pointer device disappears while a button is held; every 4th round released on the menu bar after the tiling
# preview delay, so the window tiles to fill), double-click zoom, zoom button, close
# button, press-move-away cancel, and (when the plugin advertises "minimize" and grassfield-shell runs)
# minimize button + restore through a click on the Dock tile.
# The double-click rounds expect Settings windows.titlebarDoubleClick = zoom (the default).
# The Dock tile is clicked only after the window was seen moving to special:minimized (socket2 movewindowv2), at the
# centre of the rectangle the shell sent for that window (the plugin's log line, as in tests/compositor/minimize.sh), or,
# when the plugin's request log budget held that line back, the previous such rectangle while exactly one window is
# minimized; otherwise the tile is not clicked (counted). So the click lands on that (foot) window's minimized tile, never
# on another Dock tile; the tile clicked first and one capture of the Dock at the first minimize are logged.
# With `stages`: the Stages flag on, the strip stand-in tests/compositor/stages-fixture mapped on SOAK_OUTPUT and op "on"
# sent (verbs through scripts/nestctl); every 5th round one long-lived window is moved into a strip stage of its own, every
# 7th round the stage in tile 0 is activated (a swap), so that windows keep entering and leaving the strip (blocked and
# transformed) while the churn goes on. Every window is a foot with the default app id (no extra Dock tile).
# Where a window opens is the compositor's business: each window's rectangle is read from `hyprctl -j clients`
# (tests/compositor/window_geometry.sh) and its REAL titlebar and buttons are aimed at (SOAK_OUTPUT, default GF-REF).
# Every action counts attempts and effective actions (the window moved, resized, closed, minimized and restored,
# observed on its geometry), tests/compositor/soak_lib.sh.
# Verdict:
#   PASS (exit 0)   the nested Hyprland is alive, no core dump of its PID since the start (dumps of other Hyprland
#                   instances are listed, not counted), no grassfield exception in its log (which must be readable),
#                   grassfield-shell kept its PID (no crash, no restart), at least SOAK_MIN_EFFECTIVE_PCT (50) % of
#                   the actions of every type took effect, the RSS slope of Hyprland and of the shell after a
#                   SOAK_RSS_WARMUP_S (300) warm-up is at most SOAK_MAX_RSS_MB_H (10) MB/h (judged from 5 samples
#                   and 10 minutes on; a shorter run says "not judged"), and a minimize animated;
#   FAIL (exit 1)   any of those violated;
#   2               usage or environment error, or HARNESS ERROR: no live plugin "minimize" or shell, an action
#                   type that never ran, or one that never took effect while NO other titlebar action did either
#                   (0 minimize/restore rounds is not a pass). An action type that never takes effect while the other
#                   titlebar actions do is a FAIL of the product, not a harness error.
# Log: .dev/soak-<timestamp>.log; RSS samples: .dev/soak-rss-{hyprland,shell}-<epoch>.tsv.
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
pool_max=4

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

# A window opens on the focused output, and a fresh nested session focuses WAYLAND-1, not $out: make $out the focused
# output (compositor focus, then the pointer parked on it; as tests/visual/flow-lib.sh fl_focus_output) before every
# window the churn opens. Returns 1 when the focus did not take.
focus_out() {
  timeout 10 "$root/scripts/nestctl" dispatch "hl.dsp.focus({ monitor = '$out' })" >/dev/null 2>&1 || true
  pointer abs $((out_w / 2)) $((out_h / 2))
  local n
  for n in 1 2 3 4 5 6; do
    [[ $(timeout 10 "$root/scripts/nestctl" monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .name' | head -n 1) == "$out" ]] && return 0
    sleep 0.25
  done
  return 1
}
focus_out || { echo "soak: harness error: could not make $out the focused output (the churn windows would open on another output)" >&2; exit 2; }

# shellcheck source=soak_lib.sh
. "$root/tests/compositor/soak_lib.sh"
# shellcheck source=window_geometry.sh
. "$root/tests/compositor/window_geometry.sh"
gf_geom_init || { echo "soak: output $out not listed by hyprctl monitors" >&2; exit 2; }

# Minimize rounds: plugin feature (read-only `hyprctl grassfield`) and a running shell (Dock, minimize-request).
# Without either the run cannot cover minimize/restore at all: a harness error (exit 2), never a silent pass (GF-006).
minimize_rounds=0
follow=/dev/null follow_pid=""
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
if ! HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -e '.features | index("minimize")' >/dev/null 2>&1; then
  echo "soak: harness error: the loaded plugin does not advertise \"minimize\" (load grassfield-compositor in the nested instance)" >&2
  exit 2
fi
if [[ -z $shell_pid ]] || ! kill -0 "$shell_pid" 2>/dev/null; then
  echo "soak: harness error: no live grassfield-shell of this tree ($dev/shell.pid): minimize/restore through the Dock cannot run (just shell-run)" >&2
  exit 2
fi
if true; then
  minimize_rounds=1
  # The Dock tile is the one the shell computed: the plugin logs the rectangle the shell sent with each minimize
  # ("minimize <hex>: toward the Dock rectangle x,y wxh"), read from Hyprland's log as it is written (read-only
  # `hyprctl rollinglog -f` through scripts/nestctl). Nothing about the Dock layout is computed here.
  follow=$dev/soak-follow-$start_epoch.log
  # Line-buffered (stdbuf): hyprctl's stdout into a file is block-buffered and a line could reach it seconds late.
  timeout $((duration + 600)) stdbuf -oL "$root/scripts/nestctl" rollinglog -f >"$follow" 2>&1 &
  follow_pid=$!
  read -r out_x out_y < <(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y)"')
fi
follow_lines() { grep -ac "" "$follow" 2>/dev/null || echo 0; }
# "<output> <x> <y>": the centre of the Dock tile the shell computed for window <hex>, on the output it lies on (relative to
# that output: with two outputs the Dock lives on the one whose bottom edge the pointer reached last, not always $out;
# integrator nested pass of 412b42e, restore 0/0), from line <since> on of the follow log or from Hyprland's in-memory log
# read through scripts/nestctl as tiling.sh does (`rollinglog`: the follow pipe can deliver a line late or not at all,
# integrator nested passes of 6355acb and 9c4c568; the plugin logs the line when the minimize starts, before the window
# reaches special:minimized, so the latest one for <hex> is this minimize's unless the plugin's minimize log budget held it
# back); waits up to 3 s; nothing when the line never came or lies off every output.
dock_tile() { # <hex> <since>
  local line rx ry rw rh cx cy deadline=$(($(date +%s%3N) + 3000)) pattern="\[grassfield\] minimize $1: toward the Dock rectangle " snapshot
  while :; do
    line=$(tail -n +"$(($2 + 1))" "$follow" 2>/dev/null | grep -a "$pattern" | tail -n 1)
    [[ -n $line ]] && break
    snapshot=$(nestctl rollinglog 2>/dev/null)
    line=$(grep -a "$pattern" <<<"$snapshot" | tail -n 1)
    [[ -n $line ]] && break
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
  read -r rx ry rw rh < <(sed -n 's/.*toward the Dock rectangle \(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p' <<<"$line")
  [[ -n ${rh:-} ]] || return 1
  cx=$((rx + rw / 2)) cy=$((ry + rh / 2))
  nestctl monitors -j 2>/dev/null | jq -r --argjson x "$cx" --argjson y "$cy" \
    '[.[] | select($x >= .x and $x < .x + .width and $y >= .y and $y < .y + .height)][0] | select(. != null) | "\(.name) \($x - .x) \($y - .y)"'
}
pointer_on() { local o=$1; shift; timeout 20 "$root/scripts/dev/pointer.sh" output "$o" "$@" >>"$log" 2>&1; }
minimized_count() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null | jq '[.[] | select(.workspace.name == "special:minimized")] | length'; }
restore_tile="" # the latest tile ("<output> <x> <y>") the shell named while exactly one window was minimized
rand_x() { echo $((100 + RANDOM % (out_w - 200))); }
rand_y() { echo $((80 + RANDOM % (out_h - 280))); }

pool=()      # churn windows, oldest first
resident=() # long-lived windows (whole run)
spawned=0 short=0 skipped=0 round=0 unmapped=0
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
  [[ -n ${follow_pid:-} ]] && kill "$follow_pid" 2>/dev/null
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
# The Stages state: the `stages` event is only a change notice (Hyprland cuts socket2 events at 1024 bytes; ADR-0007
# amendment 2026-10-24), the state comes from the request socket.
st_last() { nestctl grassfield-stages 2>/dev/null; }
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
((minimize_rounds)) && say "soak: Dock: the minimized foot tile is clicked only after its window moved to special:minimized, at the centre of the rectangle the shell sent for it (plugin log line; else the previous one while exactly one window is minimized, else not clicked)"
((stages_mode)) && say "soak: Stages on (strip stand-in on $out, 4 tiles); resident windows moved into strip stages every 5th round, tile 0 activated every 7th"

# --- effect accounting (GF-006) ---------------------------------------------------------------------------------
# Every action type counts attempts and EFFECTIVE actions: the effect was observed on the window's real geometry
# (`hyprctl -j clients`), never assumed. The verdict needs a minimum share of effective actions per type; a type that
# never ran, or never took effect, is a harness error (exit 2), not a pass.
declare -A att=() eff=()
try_() { att[$1]=$((${att[$1]:-0} + 1)); }
ok_() { eff[$1]=$((${eff[$1]:-0} + 1)); }
min_pct=${SOAK_MIN_EFFECTIVE_PCT:-50}
max_rss_mb_h=${SOAK_MAX_RSS_MB_H:-10}
rss_warmup_s=${SOAK_RSS_WARMUP_S:-300}
rss_hypr_file=$dev/soak-rss-hyprland-$start_epoch.tsv
rss_shell_file=$dev/soak-rss-shell-$start_epoch.tsv
: >"$rss_hypr_file"
: >"$rss_shell_file"
last_sample=0
shell_changed=0
rss_of() { awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null; }
# Every 30 s: RSS samples of Hyprland and of the shell, and the shell's identity (a changed or vanished PID is a
# crash or restart of grassfield-shell).
sample_tick() {
  local now r cur
  now=$(date +%s)
  ((now - last_sample >= 30)) || return 0
  last_sample=$now
  r=$(rss_of "$hypr_pid")
  [[ $r =~ ^[0-9]+$ ]] && echo "$now $r" >>"$rss_hypr_file"
  if cur=$(dev_live_pid "$dev/shell.pid") && [[ $cur == "$shell_pid" ]]; then
    r=$(rss_of "$shell_pid")
    [[ $r =~ ^[0-9]+$ ]] && echo "$now $r" >>"$rss_shell_file"
  elif ((!shell_changed)); then
    shell_changed=1
    say "check: grassfield-shell (pid $shell_pid) crashed or was restarted: record now '${cur:-gone}'"
  fi
}
# Waits up to <ms> for the window of <pid> to differ from <geometry>; prints the new one.
wait_changed() { # <pid> <geometry> [ms]
  local deadline=$(($(date +%s%3N) + ${3:-1500})) g
  while :; do
    g=$(gf_window_geom "$1" 300) && gf_geom_moved "$g" "$2" && { echo "$g"; return 0; }
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.1
  done
}
# A target at least 150 px from <x>,<y>, clear of the menu bar and the Dock.
far_point() { # <x> <y>
  local tx ty n=0
  while ((n++ < 20)); do
    tx=$(rand_x) ty=$(rand_y)
    awk -v a="$1" -v b="$2" -v c="$tx" -v d="$ty" 'BEGIN { exit !((a - c) ^ 2 + (b - d) ^ 2 >= 22500) }' && break
  done
  echo "$tx $ty"
}
# True when the compositor's cursor is within 3 px of <x>,<y> (output coordinates): the aim was reached.
cursor_at() { # <x> <y>
  HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j cursorpos 2>/dev/null \
    | jq -e --argjson x "$1" --argjson y "$2" --argjson ox "$GF_OUT_X" --argjson oy "$GF_OUT_Y" \
      '((.x - $ox - $x) | fabs) <= 3 and ((.y - $oy - $y) | fabs) <= 3' >/dev/null 2>&1
}
# True when a mapped window of <pid> is on screen on any output and not on a special workspace (minimized windows are).
visible_anywhere() { # <pid>
  HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null \
    | jq -e --argjson p "$1" '[.[] | select(.pid == $p and .mapped == true and ((.workspace.name // "") | startswith("special:") | not))] | length > 0' >/dev/null 2>&1
}

counters() { local t out=""; for t in drag abandoned zoom-dblclick zoom-button cancel close minimize restore; do out+="$t ${eff[$t]:-0}/${att[$t]:-0}, "; done; echo "${out%, }"; }

while (( $(date +%s) < end_epoch )); do
  round=$((round + 1))

  if ! kill -0 "$hypr_pid" 2>/dev/null; then
    say "soak: nested Hyprland (pid $hypr_pid) died at round $round"
    break
  fi
  sample_tick
  if ((shell_changed)); then break; fi

  # Long-lived windows: two of them for the whole run (respawned if one was closed by a click).
  alive=()
  for p in "${resident[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
  resident=("${alive[@]}")
  while (( ${#resident[@]} < 2 )); do
    focus_out || say "soak: warning: $out is not the focused output (a window may open elsewhere)"
    resident+=("$(foot_bg -e sleep "$duration")")
    sleep 0.6
    # Out of the way: grab the new window's real titlebar.
    if rg=$(gf_window_geom "${resident[-1]}" 3000); then
      read -r rx ry rw rh <<<"$rg"
      read -r rbx rby <<<"$(gf_bar_point "$rx" "$ry" "$rw" "$rh")"
      read -r rtx rty <<<"$(far_point "$rbx" "$rby")"
      pointer abs "$rbx" "$rby" sleep 50 down drag "$rtx" "$rty" sleep 30 up
    fi
  done

  # Short-lived window: maps and unmaps at once.
  foot_bg -e true >/dev/null
  short=$((short + 1))

  # Churn window: a new one each round. The oldest of pool_max is killed first (abrupt client disconnect); others end
  # through the close button. Its title bar is found from its real geometry, wherever the compositor placed it.
  alive=()
  for p in "${pool[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
  pool=("${alive[@]}")
  if (( ${#pool[@]} >= pool_max )); then
    kill "${pool[0]}" 2>/dev/null
    pool=("${pool[@]:1}")
  fi
  # A churn window may have moved the focus: $out again before this one opens. A focus that does not take counts as a
  # round without the new window (unmapped), which fails the run as a harness error when frequent.
  if ! focus_out; then
    spawned=$((spawned + 1))
    unmapped=$((unmapped + 1))
    say "soak: warning: $out is not the focused output: round skipped"
    continue
  fi
  pool+=("$(foot_bg -e sleep 600)")
  npid=${pool[-1]}
  spawned=$((spawned + 1))
  sleep 0.7 # let it map
  if ! ng=$(gf_window_geom "$npid" 4000); then
    unmapped=$((unmapped + 1)) # no window of the new foot on $out: counted, and it fails the run when frequent
    sleep 0.3
    continue
  fi
  read -r nx ny nw nh <<<"$ng"
  read -r bx by <<<"$(gf_bar_point "$nx" "$ny" "$nw" "$nh")"

  case $((round % (7 + minimize_rounds))) in
    0 | 1) # drag the newest window somewhere and release; every 4th round onto the menu bar, held past the preview delay,
      # so that it tiles to fill (a tiling action in the churn, docs/specs/tiling.md TL17)
      try_ drag
      gx=$((bx + RANDOM % 80 - 40))
      if ((round % 4 == 0)); then
        tx=$((out_w / 2)) ty=2 hold=$((350 + RANDOM % 300))
        fills=$((${fills:-0} + 1))
      else
        read -r tx ty <<<"$(far_point "$gx" "$by")"
        hold=30
      fi
      pointer abs "$gx" "$by" sleep 50 down drag "$tx" "$ty" sleep "$hold" up
      wait_changed "$npid" "$ng" 1500 >/dev/null && ok_ drag ;;
    2) # abandon a drag: the virtual pointer goes away with the button held; then click elsewhere
      try_ abandoned
      read -r tx ty <<<"$(far_point "$bx" "$by")"
      pointer abs "$bx" "$by" sleep 50 down drag "$tx" "$ty"
      pointer abs "$(rand_x)" "$(rand_y)" sleep 50 click
      wait_changed "$npid" "$ng" 800 >/dev/null && ok_ abandoned ;;
    3) # double-click zoom, twice (maximize, restore): effective when the size changed and then changed back
      try_ zoom-dblclick
      pointer abs "$bx" "$by" sleep 50 click sleep 60 click sleep 500
      if zg=$(wait_changed "$npid" "$ng" 1500); then
        read -r zx zy zw zh <<<"$zg"
        read -r zbx zby <<<"$(gf_bar_point "$zx" "$zy" "$zw" "$zh")"
        pointer abs "$zbx" "$zby" sleep 50 click sleep 60 click sleep 300
        wait_changed "$npid" "$zg" 1500 >/dev/null && ok_ zoom-dblclick
      fi ;;
    4) # zoom button, twice
      try_ zoom-button
      read -r px py <<<"$(gf_button_point zoom "$nx" "$ny" "$nw" "$nh")"
      pointer abs "$px" "$py" sleep 50 click sleep 500
      if zg=$(wait_changed "$npid" "$ng" 1500); then
        read -r zx zy zw zh <<<"$zg"
        read -r px py <<<"$(gf_button_point zoom "$zx" "$zy" "$zw" "$zh")"
        pointer abs "$px" "$py" sleep 50 click sleep 300
        wait_changed "$npid" "$zg" 1500 >/dev/null && ok_ zoom-button
      fi ;;
    5) # press the close button, move away, release: must not close (and must not drag the window)
      read -r px py <<<"$(gf_button_point close "$nx" "$ny" "$nw" "$nh")"
      read -r tx ty <<<"$(far_point "$px" "$py")"
      # Effective only when the compositor reports the pointer on the button at the press, the window survived the
      # release away from it and did not move: a press that missed proves nothing.
      pointer abs "$px" "$py" sleep 120
      landed=0
      cursor_at "$px" "$py" && landed=1
      pointer abs "$px" "$py" sleep 50 down drag "$tx" "$ty" sleep 30 up
      sleep 0.3
      # A press the compositor did not see on the button is a harness miss: not an attempt (counted and reported, never a FAIL).
      if ((landed)); then try_ cancel; else cancel_missed=$((${cancel_missed:-0} + 1)); fi
      if ((landed)) && kill -0 "$npid" 2>/dev/null && cg=$(gf_window_geom "$npid" 1000) && ! gf_geom_moved "$cg" "$ng"; then ok_ cancel; fi ;;
    6) # close the newest window with its close button
      try_ close
      read -r px py <<<"$(gf_button_point close "$nx" "$ny" "$nw" "$nh")"
      pointer abs "$px" "$py" sleep 50 click
      gf_window_gone "$npid" 2500 && ok_ close ;;
    7) # minimize the newest window with its button, restore it from its Dock tile (while it may still animate). The
      # tile is clicked only once the window moved to special:minimized: otherwise there is no minimized tile there.
      try_ minimize
      m0=$(moves_to_minimized)
      f0=$(follow_lines)
      read -r px py <<<"$(gf_button_point min "$nx" "$ny" "$nw" "$nh")"
      pointer abs "$px" "$py" sleep 50 click
      moved=0
      for _ in $(seq 1 30); do
        (($(moves_to_minimized) > m0)) && { moved=1; break; }
        sleep 0.05
      done
      tile=""
      if ((moved)); then
        ok_ minimize
        mhex=$(grep -E '^movewindowv2>>[0-9a-f]+,[^,]*,special:minimized$' "$events" | tail -n 1 | sed 's/^movewindowv2>>\([0-9a-f]*\),.*/\1/')
        tile=$(dock_tile "$mhex" "$f0")
        if [[ -n $tile && $(minimized_count) == 1 ]]; then
          restore_tile=$tile
        elif [[ -z $tile && -n $restore_tile && $(minimized_count) == 1 ]]; then
          tile=$restore_tile # line held back by the log budget: the same Dock with one minimized window
          dock_cached=$((${dock_cached:-0} + 1))
        fi
      fi
      if [[ -n $tile ]]; then
        sleep "0.$((150 + RANDOM % 400))"
        read -r to tx ty <<<"$tile"
        if [[ -z $dock_shot ]]; then
          dock_shot=$dev/soak-dock-$start_epoch.png
          WAYLAND_DISPLAY=$sock grim -l 0 -o "$to" "$dock_shot" 2>>"$log" && say "soak: Dock captured at the first minimize: $dock_shot (tile clicked at $tx,$ty on $to)"
        fi
        try_ restore
        pointer_on "$to" abs "$tx" "$ty" sleep 50 click sleep 300
        # Restored: the window is on screen again (on any output: where it lands is not this harness's question).
        for _ in $(seq 1 40); do visible_anywhere "$npid" && { ok_ restore; break; }; sleep 0.1; done
      elif ((moved)); then
        no_tile=$((${no_tile:-0} + 1)) # minimized, but no Dock rectangle known for it: its tile is not clicked
        # Why, for the report: no line at all (the shell sent no rectangle, or the budget held it back), or a rectangle off
        # every output.
        snapshot=$(nestctl rollinglog 2>/dev/null)
        if grep -aq "minimize $mhex: toward the Dock rectangle " <<<"$snapshot"; then no_tile_off=$((${no_tile_off:-0} + 1)); else no_tile_line=$((${no_tile_line:-0} + 1)); fi
      else
        skipped=$((skipped + 1)) # the minimize button press did not minimize the window
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
    say "soak: round $round, $(( $(date +%s) - start_epoch ))s, short $short, churn $spawned (unmapped $unmapped), resident ${#resident[@]}, effective/attempted: $(counters), minimize skipped $skipped, stages moves $st_moves swaps $st_swaps, RSS $(rss_kb) kB"
  fi
  sleep 0.3
done
sample_tick

elapsed=$(( $(date +%s) - start_epoch ))
say "soak: done after ${elapsed}s, $round rounds: short $short, churn $spawned (no window found for $unmapped), effective/attempted: $(counters)"
((${cancel_missed:-0} > 0)) && say "soak: cancel: ${cancel_missed} press(es) did not land on the button (harness miss, not counted as attempts)"
say "soak: drags released on the menu bar to fill (tiling): ${fills:-0} of ${att[drag]:-0}"
say "soak: minimize: pressed but window not minimized: $skipped; minimized without a known Dock tile, not clicked: ${no_tile:-0} (no Dock line from the plugin: ${no_tile_line:-0}; a rectangle off every output: ${no_tile_off:-0}); previous tile reused: ${dock_cached:-0}"
((stages_mode)) && say "soak: Stages: $st_moves move-to-new-stage and $st_swaps activate requests, $(grep -ac 'grassfield>>{"v":"gfc/1","type":"stages"' "$events") stages events, still on: $(st_last | jq -r '.on')"

fail=0 harness=0
if kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: nested Hyprland pid $hypr_pid alive, RSS $(rss_kb) kB"
else
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi

if ((shell_changed)); then
  say "check: FAIL grassfield-shell crashed or restarted during the run"
  fail=1
elif cur=$(dev_live_pid "$dev/shell.pid") && [[ $cur == "$shell_pid" ]]; then
  say "check: grassfield-shell pid $shell_pid unchanged (no crash, no restart)"
else
  say "check: FAIL grassfield-shell (pid $shell_pid) is gone"
  fail=1
fi

# Effective actions: a type that never ran, or never took effect while nothing else did, is a harness error; a low share, or
# none while other titlebar actions work, is a failure of the product.
# Some titlebar action took effect: the harness reaches the windows, so an action type that never works is the product's.
others_any() { local t; for t in drag zoom-dblclick zoom-button close minimize; do [[ $t != "$1" ]] && ((${eff[$t]:-0} > 0)) && return 0; done; return 1; }
for t in drag abandoned zoom-dblclick zoom-button cancel close minimize restore; do
  a=${att[$t]:-0} e=${eff[$t]:-0}
  o=0
  others_any "$t" && o=1
  if [[ $t == abandoned ]]; then
    # Whether an abandoned drag moves the window is the compositor's choice: it must run, its effect is only reported.
    v=ok
    ((a > 0)) || v=harness
  else
    v=$(soak_action_verdict "$a" "$e" "$min_pct" "$o")
  fi
  case $v in
    ok) say "check: $t: $e of $a effective" ;;
    harness) say "check: HARNESS ERROR $t: $e of $a effective (the harness could not drive it: no verdict on the product)"; harness=1 ;;
    fail) say "check: FAIL $t: only $e of $a effective (minimum $min_pct %; if 0, the other titlebar actions did take effect)"; fail=1 ;;
  esac
done
v=$(soak_action_verdict "$spawned" "$((spawned - unmapped))" "$min_pct")
case $v in
  ok) : ;;
  *) say "check: HARNESS ERROR the new window was found in only $((spawned - unmapped)) of $spawned rounds"; harness=1 ;;
esac

# Memory: the slope of Hyprland's and the shell's RSS after the warm-up, against a stated bound.
for pair in "Hyprland:$rss_hypr_file" "grassfield-shell:$rss_shell_file"; do
  name=${pair%%:*} file=${pair#*:}
  slope=$(soak_slope_mb_h "$file" "$rss_warmup_s")
  case $(soak_rss_verdict "$slope" "$max_rss_mb_h") in
    ok) say "check: $name RSS slope $slope MB/h <= $max_rss_mb_h MB/h ($(grep -c '' "$file") samples, after ${rss_warmup_s}s warm-up)" ;;
    fail) say "check: FAIL $name RSS slope $slope MB/h > $max_rss_mb_h MB/h ($(grep -c '' "$file") samples, after ${rss_warmup_s}s warm-up; $file)"; fail=1 ;;
    unjudged) say "check: $name RSS slope not judged (needs 5 samples and 10 min after a ${rss_warmup_s}s warm-up; this run is too short: $(grep -c '' "$file") samples)" ;;
  esac
done

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
  say "check: FAIL nested log $hyprlog is not readable: exceptions cannot be checked, the run proves nothing"
  fail=1
fi

total=$(grep -c 'grassfield>>{"v":"gfc/1","type":"minimized"' "$events" 2>/dev/null)
rejected=$(( $(grep -c 'minimize [0-9a-f]*: no valid Dock rectangle' "$hyprlog" 2>/dev/null) - rejected_before ))
animated=$((total - rejected))
say "check: minimizes: $total total, $animated animated, $rejected rejected (no valid Dock rectangle)"
if (( animated <= 0 )); then
  say "check: FAIL no minimize animated although the plugin advertises minimize"
  fail=1
fi

# A failure of the product wins over a harness error: both are reported above.
if ((fail)); then say "soak: FAIL"; rc=1
elif ((harness)); then say "soak: HARNESS ERROR (no valid evidence; exit 2)"; rc=2
else say "soak: PASS"; rc=0; fi
say "soak: log $log"
exit "$rc"
