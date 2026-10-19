#!/usr/bin/env bash
# Dock motion on the nested output, Reduce Motion OFF: bursts of frames (grim on the nested output only, as many frames as it
# delivers, a few per 100 ms) while the Dock changes, with the position of a coloured test icon tracked per frame.
#   open   a second app opens: the first one's tile glides to its new place (no jump, no overshoot)
#   quit   an unpinned app quits: its tile glides from the apps section into the recents section
#   land   a recents tile is launched (its app opens a window after a delay): the icon hops, then lands with a bounce when
#          the window appears
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-motion.sh
# Output: .dev/visual/dock-motion/<burst>.txt (time ms, x left, x centre, y top, pixels per frame), frames kept as PPM.
# Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"

out=$VS_STATE/dock-motion
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${rec_pid:-} ]] && kill "$rec_pid" 2>/dev/null || true
  # Clients of the test (foot windows outlive the nested compositor): close them first.
  vs_nested_running && vs_kill_clients || true
  # A window started from the Dock (the landing burst) is not a tracked client: close it (its own process) before the session ends.
  if vs_nested_running; then
    local pid
    for pid in $("$VS_ROOT/scripts/nestctl" clients -j 2>/dev/null | jq -r '.[] | select(.class == "gfmA" or .class == "gfmB") | .pid' 2>/dev/null); do
      dev_may_signal "$pid" && kill "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM


mkdir -p "$out" "$VS_DEV/share/applications" "$VS_DEV/share/gfmotion"
rm -f "$out"/*
# Test apps: a magenta and a cyan icon (pure colours); gfmA starts slowly when launched from the Dock (its window appears
# about 1.5 s after the click: several hops, the window then appears in the middle of a hop). The windows themselves are plain foot windows with these app ids.
magick -size 64x64 xc:'#ff00ff' "$VS_DEV/share/gfmotion/a.png"
magick -size 64x64 xc:'#00ffff' "$VS_DEV/share/gfmotion/b.png"
printf '[Desktop Entry]\nType=Application\nName=GF Motion A\nExec=sh -c "sleep 1.45; exec foot --app-id gfmA"\nIcon=%s\n' "$VS_DEV/share/gfmotion/a.png" > "$VS_DEV/share/applications/gfmA.desktop"
printf '[Desktop Entry]\nType=Application\nName=GF Motion B\nExec=foot --app-id gfmB\nIcon=%s\n' "$VS_DEV/share/gfmotion/b.png" > "$VS_DEV/share/applications/gfmB.desktop"

# Test windows left by an earlier run (their own processes, started by this script) go first, before the session is reset.
vs_nested_running && for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.class == "gfmA" or .class == "gfmB") | .pid'); do
  dev_may_signal "$pid" && kill "$pid" || true
done
vs_sleep 2

vs_session en
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null
sock=$(vs_nested_wayland)
# Frame region (global coordinates): the Dock of GF-REF and the room above it for the hop.
origin=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.x) \(.y)"')
REGION="$(( ${origin% *} + 560 )),$(( ${origin#* } + 930 )) 800x150"

# record NAME MILLISECONDS: frames of REGION in the background until the time is up (rec_pid).
record() {
  local name=$1 ms=$2
  (
    i=0
    end=$(( $(date +%s%3N) + ms ))
    : > "$out/$name.log"
    while (( $(date +%s%3N) < end )); do
      WAYLAND_DISPLAY=$sock grim -t ppm -g "$REGION" "$out/$name-$(printf %03d "$i").ppm"
      echo "$i $(date +%s%3N)" >> "$out/$name.log"
      i=$((i + 1))
    done
  ) &
  rec_pid=$!
}

analyse() { python3 -I "$VS_HERE/dock-motion.py" "$out" "$1" "$2" "$3" > "$out/$1.txt" || fail=1; }

fail=0

# Setup: A running (unpinned): foot, A, separator, Trash.
vs_spawn foot --app-id gfmA
vs_sleep 3
VS_SETTLE=0.3 vs_capture dock-motion-start >/dev/null

# 1. open: B appears, the shelf widens, A's tile moves.
record open 2400
vs_sleep 0.5
vs_spawn foot --app-id gfmB
wait "$rec_pid"; rec_pid=""
analyse open magenta glide

# 2. quit: A quits and goes to the recents section.
record quit 2400
vs_sleep 0.5
# The foot window of A only (its own process, started by this script).
pidA=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.class == "gfmA") | .pid' | head -n 1)
[[ $pidA =~ ^[0-9]+$ ]] && dev_may_signal "$pidA" && kill "$pidA"
wait "$rec_pid"; rec_pid=""
analyse quit magenta glide

# 3. land: B quits too (recents: B, A), then A is launched from the Dock (items: foot, divider, B, A, separator, Trash).
vs_kill_clients
vs_sleep 3
VS_SETTLE=0.3 vs_capture dock-motion-recents >/dev/null
record land 4200
vs_sleep 0.4
vs_ipc dock click 3 >/dev/null
wait "$rec_pid"; rec_pid=""
analyse land magenta land
vs_kill_clients

for n in open quit land; do
  echo "== $n (ms, x left, x centre, y top, pixels)"
  # consecutive frames at the same place are collapsed ("... xN")
  awk '{ k = $2 " " $3 " " $4 " " $5; if (k == prev) { rep++; next } if (rep) printf "  ... x%d\n", rep; rep = 0; prev = k; print } END { if (rep) printf "  ... x%d\n", rep }' "$out/$n.txt"
done
exit $fail
