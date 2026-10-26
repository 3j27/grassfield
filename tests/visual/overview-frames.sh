#!/usr/bin/env bash
# Gate P3 (docs/specs/overview.md "Measuring P3 and S4"): smoothness of the Overview open and close, measured on the nested
# session with the frame-callback probe tests/tools/framepulse (a small window that redraws on every frame callback and prints
# the time between two callbacks) while the Overview opens and closes CYCLES times with the Balanced profile and Reduce Motion
# off. tests/visual/frame-stats.py turns the intervals into the share of frames within 1.2 refresh periods (a frame the
# compositor drops or delays shows as two periods): PASS at 95 % or more, in the open phase, the close phase and overall.
#   tests/visual/overview-frames.sh [CYCLES=6] [PROFILE=balanced]
# Run as a BARE command with a relative path, on the reference machine only; the nested session it starts is torn down on exit.
# The nested output is software-rendered or goes through the parent compositor: the numbers are an indication; the gate itself
# is run by the owner on the real session (L2, same script against a session that is not nested is not supported here).
# Output: .dev/visual/overview-frames/{frames.txt,events.txt,stats.txt}. Exit status 1 when a phase is below 95 %.
source "$(dirname "$0")/lib.sh"
set +e

cycles=${1:-6}
profile=${2:-balanced}
[[ $cycles =~ ^[1-9][0-9]*$ && $profile =~ ^(full|balanced|reduced)$ ]] || { echo "usage: overview-frames.sh [CYCLES] [full|balanced|reduced]" >&2; exit 2; }
out=$VS_STATE/overview-frames
was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_ipc overview close >/dev/null 2>&1 || true; vs_kill_clients || true; }
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*

# The probe, built once into .dev/tools (the xdg-shell glue is generated from the system protocol file).
build_probe() {
  local tools=$VS_DEV/tools xml=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
  mkdir -p "$tools"
  [[ -x $tools/framepulse && $VS_ROOT/tests/tools/framepulse/framepulse.c -ot $tools/framepulse ]] && return 0
  wayland-scanner client-header "$xml" "$tools/xdg-shell-client-protocol.h" &&
    wayland-scanner private-code "$xml" "$tools/xdg-shell-protocol.c" &&
    gcc -std=gnu11 -O1 -Wall -Wextra -I"$tools" "$VS_ROOT/tests/tools/framepulse/framepulse.c" "$tools/xdg-shell-protocol.c" \
      $(pkg-config --cflags --libs wayland-client) -o "$tools/framepulse"
}
build_probe || { echo "FAIL the probe did not build (wayland-scanner, gcc, wayland-client)"; exit 1; }

# The Balanced profile (or the one asked for) through the settings file the shell watches.
set_profile() {
  local f=$VS_DEV/config/grassfield.json tmp
  mkdir -p "$(dirname "$f")"
  [[ -s $f ]] || echo '{"version":1}' >"$f"
  tmp=$(mktemp "$f.XXXXXX") && jq --arg p "$1" '.material.profile = $p' "$f" >"$tmp" && mv "$tmp" "$f"
}

vs_session en
set_profile "$profile"
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null
for i in 1 2 3 4 5 6; do
  vs_foot "Terminal $i" 60x16
  vs_wait_clients "$i"
done
vs_park

hz=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '[.[] | select(.name == "'"$VS_OUTPUT"'") | .refreshRate][0] // 60')
span=$(( cycles * 3 + 4 ))
# Like vs_spawn (nested socket only, isolated environment) but with the output kept.
"$VS_ROOT/scripts/dev/isolated.sh" --name framepulse --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
  env WAYLAND_DISPLAY="$(vs_nested_wayland)" "$VS_DEV/tools/framepulse" "$span" >"$out/frames.txt" 2>"$out/probe.err" &
probe=$!
vs_track "$probe"
sleep 3

now_ns() { date +%s%N; }
for ((c = 1; c <= cycles; c++)); do
  echo "open $(now_ns)" >>"$out/events.txt"
  vs_ipc overview open >/dev/null
  sleep 1.2
  echo "close $(now_ns)" >>"$out/events.txt"
  vs_ipc overview close >/dev/null
  sleep 1.6
done
wait "$probe" 2>/dev/null

grep -v '^#' "$out/frames.txt" >"$out/frames.clean"
echo "profile $profile, $cycles cycles, $(wc -l <"$out/frames.clean") frames, refresh $hz Hz"
python3 -I "$VS_HERE/frame-stats.py" "$out/frames.clean" "$out/events.txt" "$hz" | tee "$out/stats.txt"
exit "${PIPESTATUS[0]}"
