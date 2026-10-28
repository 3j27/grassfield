#!/usr/bin/env bash
# Gate P3 from presentation times (ADR-0006: at least 95 % of frames on time during Dock magnification, Mission Control
# open/close and Launchpad open). The compositor plugin records the time of every frame each output presents (Hyprland's
# presentation feedback, feature "frame-times", `hyprctl grassfield-frames`, compositor/src/core/FrameLog.hpp): real shell
# animations are measured where they reach the output, not in the shell's render thread and not through a probe window.
# The same statistics as the frame-callback probe (tests/visual/overview-frames.sh): tests/visual/frame-stats.py, per
# scenario and overall, the share of frames within 1.2 refresh periods (a dropped frame shows as two periods), PASS at 95 %.
#   overview-open, overview-close   the Overview (Mission Control) opened and closed through the shell's IPC
#   launchpad-open                  the Apps panel (Launchpad) opened (then closed, not measured)
#   dock-magnification              the pointer glides along the Dock's icons and back twice (Dock magnification on, auto-hide
#                                   off), from the first tile's centre to the last one's (`qs ipc call dock centre`). Not the
#                                   middle of the Dock's layer: it spans the output's width and, above the shelf, the room for
#                                   magnified icons, outside its input mask; the glide there magnified nothing and no frame came
#                                   (integrator run 2026-10-24: the first frame 2.2 s after each request, 0 in the window)
#   overview-open-4w, -close-4w     the Overview with four windows (the plugin's live window transforms, docs/specs/overview.md)
#   overview-open-flat, -close-flat the same with Reduce Transparency on (no blur): what the blur costs, by difference
#   shared-edge                     two of the four windows arranged left and right (one tile group, the plugin's arrange),
#                                   their shared edge's handle dragged right, left and back with the button held: both windows
#                                   resized live (tiling.md TL30); skipped without the plugin's tiling-shared-edge. Judged by
#                                   frame-attribution.py --gate against edge-baseline (ADR-0036 D34 as amended, the
#                                   integrator's gate of 2026-10-28): (a) the plugin's own work at most 1 ms in every frame,
#                                   (b) its compositor-caused long frames (its render, or the event loop held before it) per
#                                   second at most 1.25 times the baseline's; its share on time printed as information (the
#                                   apps redraw at their own pace); no frame in its animation fails
#   edge-baseline                   the same two windows arranged again, the left one's right border dragged by Hyprland's own
#                                   resize_on_border, outside the handle (40 px below the surface tops), with the same glide:
#                                   what Hyprland's own live resize costs here; information, the shared edge's reference.
#                                   PERF_DRAG=1: one `perf record -g` of Hyprland's main thread during the first glide of
#                                   each (shared-edge.perf.txt, edge-baseline.perf.txt; needs perf)
# The Dock and the Launchpad in the same run tell the nested output's own pacing apart from the cost of an animation.
# The window measured is the animation itself (ADR-0006 amendment, integrator decision 2026-10-24 under D-5, the macOS
# model: a static screen owes no frames, so sparse frames once the animation is over are not misses): from the first frame
# presented after the request (the request's own latency, the qs ipc process and the shell's reaction, is printed, not
# measured) to that frame + the animation's token duration + one refresh period (tests/visual/animation-windows.py), or to
# the plugin's end mark of the Overview's phase when later (its windows start moving once the chrome holds the keyboard).
# Durations: Overview motion.slow (shell/overview/Overview.qml), Launchpad motion.normal (shell/launchpad/AppsWindow.qml),
# Dock magnification the glide as timed here + motion.fast (the Dock's settle). The interval that spans a request is left
# out. The tail, from the animation's end to WINDOW_MS after the request, is reported as information (its frames and its
# longest interval), never a verdict, so a late stall stays visible; frame-attribution.py attributes both.
#   tests/visual/presented-frames.sh [CYCLES=3] [PROFILE=balanced] [WINDOW_MS=1500]
# Run as a BARE command with a relative path; needs this tree's plugin loaded in the nested session (just plugin-build; the
# session started by nested-up loads it). The nested output is paced by Hyprland's own timer: the numbers are an indication
# of the shell's and the compositor's work per frame; the gate is the owner's L2 run on the real session.
# Output: .dev/visual/presented-frames/{frames.txt,events.txt,events.anim,windows.txt,stats.txt,attribution.txt,renders.all,
# marks.all,stalls.all,work.all,*.json[,*.perf.txt]}.
# Exit 1 when a phase is below 95 % in its animation window (the shared edge: when the compositor caused a long frame in
# it), 2 on an environment error.
source "$(dirname "$0")/lib.sh"
set +e

cycles=${1:-3}
profile=${2:-balanced}
window=${3:-1500}
[[ $cycles =~ ^[1-9][0-9]?$ && $profile =~ ^(full|balanced|reduced)$ && $window =~ ^[1-9][0-9]{2,4}$ ]] \
  || { echo "usage: presented-frames.sh [CYCLES 1-99] [full|balanced|reduced] [WINDOW_MS]" >&2; exit 2; }
out=$VS_STATE/presented-frames
was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_ipc overview close >/dev/null 2>&1 || true; vs_ipc apps close >/dev/null 2>&1 || true; }
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*

nestctl() { timeout 10 "$VS_ROOT/scripts/nestctl" "$@"; }
mono_ns() { python3 -I -c 'import time; print(time.monotonic_ns())'; }

vs_session en
nestctl -j grassfield 2>/dev/null | jq -e '.features | index("frame-times")' >/dev/null 2>&1 \
  || { echo "FAIL the plugin does not advertise frame-times (just plugin-build, then a nested session that loads it)"; exit 2; }
vs_reset dark 0.25
# Balanced profile, Dock magnification on: the settings file the shell watches (GRASSFIELD_CONFIG_HOME of the nested shell,
# emptied by vs_session); motion on through the IPC.
settings=$VS_DEV/config/grassfield.json
[[ -s $settings ]] || echo '{}' >"$settings"
tmp=$(mktemp "$settings.XXXXXX") && jq --arg p "$profile" '.material.profile = $p | .dock.magnificationEnabled = true' "$settings" >"$tmp" && mv "$tmp" "$settings"
vs_ipc controlcenter reduceMotion false >/dev/null
sleep 1.5
vs_park

hz=$(nestctl monitors -j | jq -r '[.[] | select(.name == "'"$VS_OUTPUT"'") | .refreshRate][0] // 60')
# The animations' token durations (ui/tokens/tokens.json motion.*).
read -r slow_ms normal_ms fast_ms < <(jq -r '"\(.motion.slow.value) \(.motion.normal.value) \(.motion.fast.value)"' "$VS_ROOT/ui/tokens/tokens.json")
[[ $slow_ms =~ ^[0-9]+$ && $normal_ms =~ ^[0-9]+$ && $fast_ms =~ ^[0-9]+$ ]] || { echo "FAIL no motion tokens in ui/tokens/tokens.json"; exit 2; }
read -r dx dy dw dh < <(nestctl -j layers | jq -r '[.. | objects | select(.namespace? == "grassfield-dock")][0] | "\(.x) \(.y) \(.w) \(.h)"')
# The glide: over the icons, first tile to last (output coordinates; the Dock at the bottom, not auto-hidden).
vs_ipc dock autohide false >/dev/null
vs_ipc dock position bottom >/dev/null
vs_ipc dock magnify 1.6 true >/dev/null
sleep 0.5
ntiles=$(vs_ipc dock tiles | jq -r 'length' 2>/dev/null)
[[ $ntiles =~ ^[0-9]+$ && $ntiles -gt 1 ]] || ntiles=1
read -r gx0 gy < <(vs_ipc dock centre 0 "$VS_OUTPUT")
read -r gx1 _ < <(vs_ipc dock centre $((${ntiles:-1} - 1)) "$VS_OUTPUT")
if [[ ${gx0:-} =~ ^[0-9]+$ && ${gx1:-} =~ ^[0-9]+$ && ${gy:-} =~ ^[0-9]+$ && $gx1 -gt $gx0 ]]; then
  echo "dock glide: tiles $ntiles, from ($gx0,$gy) to ($gx1,$gy) (Dock layer ${dw:-?}x${dh:-?} at (${dx:-?},${dy:-?}))"
else
  echo "NOTE dock-magnification not measured: no tile centres from the shell (tiles ${ntiles:-?}, '${gx0:-}' '${gx1:-}' '${gy:-}')"
  gx0="" gx1="" gy=""
fi

# The frames presented since the last collection, appended as "<monotonic us> <interval us>"; for the attribution, the
# render spans of the output ("<begin us> <cpu us>"), the plugin's phase marks ("<us> <name>"), the event loop's stalls and
# the plugin's own work ("<begin us> <length us>": a stall before a render reads as a late client without them) since then
# too, and the most beats the loop probe ran.
last=0 last_render=0 last_mark=0 last_stall=0 last_work=0 beats=0
collect() {
  local answer=$out/frames-$(date +%s%N).json
  nestctl -j grassfield-frames >"$answer" 2>/dev/null || return 0
  jq -r --arg o "$VS_OUTPUT" --argjson last "$last" '
    .monitors[] | select(.name == $o) | .presented as $p
    | range(1; $p | length) | select($p[.] > $last) | "\($p[.]) \($p[.] - $p[. - 1])"' \
    "$answer" >>"$out/frames.all"
  last=$(jq -r --arg o "$VS_OUTPUT" '[.monitors[] | select(.name == $o) | .presented[-1]][0] // 0' "$answer")
  jq -r --arg o "$VS_OUTPUT" --argjson last "$last_render" '
    .monitors[] | select(.name == $o) | (.renders // [])[] | select(.[0] > $last) | "\(.[0]) \(.[1])"' "$answer" >>"$out/renders.all"
  last_render=$(jq -r --arg o "$VS_OUTPUT" '[.monitors[] | select(.name == $o) | (.renders // [])[-1][0]][0] // 0' "$answer")
  jq -r --argjson last "$last_mark" '(.marks // [])[] | select(.t > $last) | "\(.t) \(.what)"' "$answer" >>"$out/marks.all"
  last_mark=$(jq -r '[(.marks // [])[-1].t][0] // 0' "$answer")
  jq -r --argjson last "$last_stall" '(.loop.stalls // [])[] | select(.[0] > $last) | "\(.[0]) \(.[1])"' "$answer" >>"$out/stalls.all"
  last_stall=$(jq -r '[(.loop.stalls // [])[-1][0]][0] // 0' "$answer")
  jq -r --argjson last "$last_work" '(.loop.work // [])[] | select(.[0] > $last) | "\(.[0]) \(.[1])"' "$answer" >>"$out/work.all"
  last_work=$(jq -r '[(.loop.work // [])[-1][0]][0] // 0' "$answer")
  local now
  now=$(jq -r '.loop.beats // 0' "$answer")
  if ((now > beats)); then beats=$now; fi
}
# The intervals that span a request (the previous frame before it, this one after it) are left out: the wait for the
# request is not a frame of the animation. <frames.all> <events.txt> -> frames.txt
drop_spanning() {
  awk 'NR == FNR { ev[NR] = int($2 / 1000); n = NR; next }
       { t = $1; i = $2; skip = 0; for (k = 1; k <= n; k++) if (t - i < ev[k] && ev[k] <= t) skip = 1; if (!skip) print }' "$2" "$1"
}
# The plugin records frames only for 60 s after a start request (never while the session is locked; FR54): every request
# asks again, so the recording covers the whole run.
frames_start() { nestctl grassfield-frames-start >/dev/null 2>&1 || true; }
event() { frames_start; echo "$1 $(mono_ns)" >>"$out/events.txt"; }

overview_round() { # <label suffix>
  event "overview-open$1"
  vs_ipc overview open >/dev/null
  sleep 1.6
  event "overview-close$1"
  vs_ipc overview close >/dev/null
  sleep 1.6
  collect
}

frames_start
sleep 0.5
collect
for ((c = 1; c <= cycles; c++)); do
  event overview-open
  vs_ipc overview open >/dev/null
  sleep 1.6
  event overview-close
  vs_ipc overview close >/dev/null
  sleep 1.6
  collect
  event launchpad-open
  vs_ipc apps open >/dev/null
  sleep 1.6
  vs_ipc apps close >/dev/null
  sleep 1.6
  collect
  if [[ -n $gx0 ]]; then
    y=$gy x0=$gx0 x1=$gx1
    vs_pointer abs "$x0" "$y" sleep 300 >/dev/null
    # The request's time, with the glide's own duration as timed (third column, read by animation-windows.py).
    frames_start
    t0=$(mono_ns)
    vs_pointer drag "$x1" "$y" drag "$x0" "$y" drag "$x1" "$y" drag "$x0" "$y" >/dev/null
    t1=$(mono_ns)
    echo "dock-magnification $t0 $(((t1 - t0) / 1000000 + fast_ms))" >>"$out/events.txt"
    sleep 0.6
    vs_park
    sleep 0.6
    collect
  fi
done

# The Overview again: with four windows (the plugin's live transforms), then without blur (Reduce Transparency).
for i in 1 2 3 4; do
  vs_foot "Terminal $i" 60x16
  vs_wait_clients "$i"
done
vs_park
for ((c = 1; c <= cycles; c++)); do overview_round -4w; done
vs_ipc controlcenter reduceTransparency true >/dev/null
sleep 1
for ((c = 1; c <= cycles; c++)); do overview_round -flat; done
vs_ipc controlcenter reduceTransparency false >/dev/null

# PERF_DRAG=1: Hyprland's main thread sampled with call graphs for SECONDS while a glide runs; the report beside the frames.
perf_drag() { # <name> <seconds>
  [[ ${PERF_DRAG:-0} == 1 ]] || return 0
  command -v perf >/dev/null || { echo "NOTE PERF_DRAG: no perf" >&2; return 0; }
  local pid
  pid=$(dev_live_pid "$VS_DEV/nested.pid") || return 0
  ( perf record -g -t "$pid" -o "$out/$1.perf.data" -- sleep "$2" >/dev/null 2>&1 &&
      perf report --stdio --no-children --percent-limit 1 -i "$out/$1.perf.data" >"$out/$1.perf.txt" 2>/dev/null ) &
  perf_pid=$!
  sleep 0.3
}
perf_wait() { [[ -n ${perf_pid:-} ]] && wait "$perf_pid" 2>/dev/null; perf_pid=""; }

# The shared edge (TL30): Terminal 1 on the left half, the next window in stacking order on the right half (one group);
# the handle in the middle of the margin between them; three glides of 20 motions 15 ms apart, the button held.
edge_measured=0 baseline_measured=0
if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-shared-edge")' >/dev/null 2>&1; then
  first=$(nestctl clients -j | jq -r '[.[] | select(.title == "Terminal 1")][0].address // ""')
  if [[ -n $first ]]; then
    nestctl dispatch "hl.plugin.grassfield.arrange('{\"layout\":\"left-right\",\"windows\":[\"$first\"]}')" >/dev/null 2>&1
    sleep 1
    read -r ox oy < <(nestctl monitors -j | jq -r --arg o "$VS_OUTPUT" '.[] | select(.name == $o) | "\(.x) \(.y)"')
    read -r lx ly lw lh < <(nestctl clients -j | jq -r --arg a "$first" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
    rx=$(nestctl clients -j | jq -r --argjson e "$((lx + lw))" '[.[] | select(.at[0] >= $e) | .at[0]] | min // empty')
    if [[ ${rx:-} =~ ^[0-9]+$ && ${ox:-} =~ ^-?[0-9]+$ ]]; then
      hx=$(((lx + lw + rx) / 2 - ox)) hy=$((ly + lh / 2 - oy))
      for ((c = 1; c <= cycles; c++)); do
        vs_pointer abs "$hx" "$hy" sleep 300 >/dev/null
        ((c == 1)) && perf_drag shared-edge 3
        frames_start
        t0=$(mono_ns)
        vs_pointer down drag $((hx + 200)) "$hy" drag $((hx - 200)) "$hy" drag "$hx" "$hy" up >/dev/null
        t1=$(mono_ns)
        echo "shared-edge $t0 $(((t1 - t0) / 1000000 + fast_ms))" >>"$out/events.txt"
        perf_wait
        sleep 0.6
        vs_park
        sleep 0.6
        collect
      done
      edge_measured=1
      # The baseline (the integrator's D34 gate, 2026-10-28): Hyprland's own resize_on_border drag of the left window's right
      # border, outside the handle (40 px below the surface tops, 2 px right of the left surface: its border grab area), the
      # same glide; each round starts from the arrangement again (Hyprland's snap can leave the edge a few px off).
      bx=$((lx + lw + 2 - ox)) by=$((ly + 40 - oy))
      for ((c = 1; c <= cycles; c++)); do
        nestctl dispatch "hl.plugin.grassfield.arrange('{\"layout\":\"left-right\",\"windows\":[\"$first\"]}')" >/dev/null 2>&1
        sleep 1
        vs_pointer abs "$bx" "$by" sleep 300 >/dev/null
        ((c == 1)) && perf_drag edge-baseline 3
        frames_start
        t0=$(mono_ns)
        vs_pointer down drag $((bx + 200)) "$by" drag $((bx - 200)) "$by" drag "$bx" "$by" up >/dev/null
        t1=$(mono_ns)
        echo "edge-baseline $t0 $(((t1 - t0) / 1000000 + fast_ms))" >>"$out/events.txt"
        perf_wait
        sleep 0.6
        vs_park
        sleep 0.6
        collect
      done
      baseline_measured=1
    fi
  fi
fi
((edge_measured)) || echo "NOTE shared-edge not measured: no tiling-shared-edge, or the two windows were not arranged"
((baseline_measured)) || echo "NOTE edge-baseline not measured (the shared edge's gate (b) fails without it)"

[[ -n $gx0 ]] || echo "NOTE dock-magnification not measured: no Dock tile centres"
drop_spanning "$out/frames.all" "$out/events.txt" >"$out/frames.txt"
echo "profile $profile, $cycles cycles, $(wc -l <"$out/frames.txt") frames ($(($(wc -l <"$out/frames.all") - $(wc -l <"$out/frames.txt"))) intervals spanning a request left out), refresh $hz Hz, tail to $window ms"
# Each request's animation window (and its tail).
python3 -I "$VS_HERE/animation-windows.py" "$out/frames.all" "$out/events.txt" "$out/marks.all" "$hz" \
  "overview=$slow_ms,launchpad=$normal_ms,dock-magnification=$((1200 + fast_ms)),shared-edge=$((900 + fast_ms)),edge-baseline=$((900 + fast_ms))" \
  "$window" "$out/events.anim" | tee "$out/windows.txt"
# The shared edge's drag is judged on its own cost and against Hyprland's own resize (ADR-0036 D34 as amended by the
# integrator: the windows show each app's buffer at its own pace, macOS's live resize); its share on time and the
# baseline's are information.
python3 -I "$VS_HERE/frame-stats.py" "$out/frames.txt" "$out/events.anim" "$hz" --info=shared-edge --info=edge-baseline | tee "$out/stats.txt"
rc=${PIPESTATUS[0]}
# Whose cost each long interval was (the compositor: its render, or the loop held before it; a client's late frame; other),
# in the animation and in its tail.
touch "$out/stalls.all" "$out/work.all"
python3 -I "$VS_HERE/frame-attribution.py" "$out/frames.txt" "$out/renders.all" "$out/marks.all" "$out/events.anim" "$hz" "$window" \
  --stalls="$out/stalls.all" --work="$out/work.all" --beats="$beats" --gate=shared-edge --baseline=edge-baseline | tee "$out/attribution.txt"
arc=${PIPESTATUS[0]}
((arc == 1)) && rc=1
exit "$rc"
