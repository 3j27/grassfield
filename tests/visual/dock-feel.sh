#!/usr/bin/env bash
# Dock feel on the nested output with the REAL pointer (Reduce Motion OFF): magnification falloff, return to rest, hover tooltip dwell and the
# auto-hide reveal from the 2 px edge strip. Captures (cropped to the Dock area) go to .dev/visual/dock-feel/ to be looked at; the script only
# asserts the observable auto-hide states (hidden with the pointer away, shown after the pointer reaches the edge strip, shown while the pointer
# is over the Dock, hidden again after it leaves).
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-feel.sh
source "$(dirname "$0")/lib.sh"
set +e
out=$VS_STATE/dock-feel
was_running=0
vs_nested_running && was_running=1
cleanup() {
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*
fails=0
check() { if [[ $2 == ok ]]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; fails=$((fails + 1)); fi; }
now() { date +%s%3N; }
crop() { # name: the Dock area of the nested output
  "$VS_ROOT/scripts/dev/shot.sh" "dockfeel-$1" "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/dockfeel-$1.png" -crop 1000x230+460+850 +repage "$out/$1.png"
  echo "shot $1 at $(now)"
}

vs_session en
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null
vs_ipc dock magnify 1.6 true >/dev/null
vs_park
vs_sleep 1.5
crop rest
for x in 900 960 1020 1080; do
  vs_pointer abs "$x" 1045 >/dev/null
  vs_sleep 0.7
  crop "mag-$x"
done
# Leave upwards: the icons settle back.
vs_pointer abs 960 600 >/dev/null
vs_sleep 0.12
crop leave-120ms
vs_sleep 0.8
crop leave-settled
# Tooltip dwell (magnification off): a frame 100 ms after arriving shows no label, one 600 ms after shows it.
vs_ipc dock magnify 1.6 false >/dev/null
vs_pointer abs 960 600 >/dev/null
vs_sleep 0.5
vs_pointer abs 960 1045 >/dev/null
vs_sleep 0.1
crop tip-100ms
vs_sleep 0.5
crop tip-600ms
# Auto-hide: states while the pointer comes to the edge strip and leaves.
vs_ipc dock autohide true >/dev/null
vs_pointer abs 960 600 >/dev/null
vs_sleep 2.5
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
echo "pointer away, after 2.5 s: $s"
[[ $s == hidden* ]] && check "autohide hides with the pointer away" ok || check "autohide hides with the pointer away" "$s"
crop hidden
vs_pointer abs 960 1079 >/dev/null
t0=$(now)
seq_states=""
for i in $(seq 1 14); do
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  seq_states+="$(( $(now) - t0 ))ms:${s%% *}/${s##* }  "
  (( i == 5 )) && crop reveal-mid
  sleep 0.06
done
echo "reveal sequence: $seq_states"
vs_sleep 0.6
crop revealed
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
[[ $s == shown* ]] && check "edge strip reveals the Dock" ok || check "edge strip reveals the Dock" "$s"
vs_pointer abs 960 1045 >/dev/null
vs_sleep 1.2
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
[[ $s == shown* ]] && check "stays shown while the pointer is over the Dock" ok || check "stays shown while the pointer is over the Dock" "$s"
vs_pointer abs 960 600 >/dev/null
vs_sleep 2.5
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
[[ $s == hidden* ]] && check "hides again after the pointer leaves" ok || check "hides again after the pointer leaves" "$s"
vs_ipc dock autohide false >/dev/null
echo "dock-feel: $fails failed; captures in $out"
exit $(( fails > 0 ))
