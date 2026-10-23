#!/usr/bin/env bash
# Gate P3 from presentation times (ADR-0006: at least 95 % of frames on time during Dock magnification, Mission Control
# open/close and Launchpad open). The compositor plugin records the time of every frame each output presents (Hyprland's
# presentation feedback, feature "frame-times", `hyprctl grassfield-frames`, compositor/src/core/FrameLog.hpp): real shell
# animations are measured where they reach the output, not in the shell's render thread and not through a probe window.
# The same statistics as the frame-callback probe (tests/visual/overview-frames.sh): tests/visual/frame-stats.py, per
# scenario and overall, the share of frames within 1.2 refresh periods (a dropped frame shows as two periods), PASS at 95 %.
#   overview-open, overview-close   the Overview (Mission Control) opened and closed through the shell's IPC
#   launchpad-open                  the Apps panel (Launchpad) opened (then closed, not measured)
#   dock-magnification              the pointer glides along the Dock and back twice (Dock magnification on for the run)
#   overview-open-4w, -close-4w     the Overview with four windows (the plugin's live window transforms, docs/specs/overview.md)
#   overview-open-flat, -close-flat the same with Reduce Transparency on (no blur): what the blur costs, by difference
# The Dock and the Launchpad in the same run tell the nested output's own pacing apart from the cost of an animation.
# Frames come only while something changes on the output: the interval that spans a request (from the last frame before it,
# often a pause with nothing to draw, to the first frame after it) is left out; every other interval counts. Each
# scenario's frames are those of the WINDOW_MS after its request.
#   tests/visual/presented-frames.sh [CYCLES=3] [PROFILE=balanced] [WINDOW_MS=1500]
# Run as a BARE command with a relative path; needs this tree's plugin loaded in the nested session (just plugin-build; the
# session started by nested-up loads it). The nested output is paced by Hyprland's own timer: the numbers are an indication
# of the shell's and the compositor's work per frame; the gate is the owner's L2 run on the real session.
# Output: .dev/visual/presented-frames/{frames.txt,events.txt,stats.txt,*.json}. Exit 1 when a phase is below 95 %, 2 on an
# environment error.
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
read -r mx my < <(nestctl monitors -j | jq -r '.[] | select(.name == "'"$VS_OUTPUT"'") | "\(.x) \(.y)"')
read -r dx dy dw dh < <(nestctl -j layers | jq -r '[.. | objects | select(.namespace? == "grassfield-dock")][0] | "\(.x) \(.y) \(.w) \(.h)"')

# The frames presented since the last collection, appended as "<monotonic us> <interval us>".
last=0
collect() {
  local answer=$out/frames-$(date +%s%N).json
  nestctl -j grassfield-frames >"$answer" 2>/dev/null || return 0
  jq -r --arg o "$VS_OUTPUT" --argjson last "$last" '
    .monitors[] | select(.name == $o) | .presented as $p
    | range(1; $p | length) | select($p[.] > $last) | "\($p[.]) \($p[.] - $p[. - 1])"' \
    "$answer" >>"$out/frames.all"
  last=$(jq -r --arg o "$VS_OUTPUT" '[.monitors[] | select(.name == $o) | .presented[-1]][0] // 0' "$answer")
}
# The intervals that span a request (the previous frame before it, this one after it) are left out: the wait for the
# request is not a frame of the animation. <frames.all> <events.txt> -> frames.txt
drop_spanning() {
  awk 'NR == FNR { ev[NR] = int($2 / 1000); n = NR; next }
       { t = $1; i = $2; skip = 0; for (k = 1; k <= n; k++) if (t - i < ev[k] && ev[k] <= t) skip = 1; if (!skip) print }' "$2" "$1"
}
event() { echo "$1 $(mono_ns)" >>"$out/events.txt"; }

overview_round() { # <label suffix>
  event "overview-open$1"
  vs_ipc overview open >/dev/null
  sleep 1.6
  event "overview-close$1"
  vs_ipc overview close >/dev/null
  sleep 1.6
  collect
}

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
  if [[ -n ${dw:-} && ${dw:-0} != null && ${dw:-0} -gt 48 ]]; then
    y=$((dy - my + dh / 2)) x0=$((dx - mx + 24)) x1=$((dx - mx + dw - 24))
    vs_pointer abs "$x0" "$y" sleep 300 >/dev/null
    event dock-magnification
    vs_pointer drag "$x1" "$y" drag "$x0" "$y" drag "$x1" "$y" drag "$x0" "$y" >/dev/null
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

[[ -n ${dw:-} && ${dw:-0} != null ]] || echo "NOTE dock-magnification not measured: no Dock layer found"
drop_spanning "$out/frames.all" "$out/events.txt" >"$out/frames.txt"
echo "profile $profile, $cycles cycles, $(wc -l <"$out/frames.txt") frames ($(($(wc -l <"$out/frames.all") - $(wc -l <"$out/frames.txt"))) intervals spanning a request left out), refresh $hz Hz, window $window ms"
python3 -I "$VS_HERE/frame-stats.py" "$out/frames.txt" "$out/events.txt" "$hz" "$window" | tee "$out/stats.txt"
exit "${PIPESTATUS[0]}"
