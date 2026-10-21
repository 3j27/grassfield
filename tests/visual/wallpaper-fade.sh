#!/usr/bin/env bash
# Crossfade of a folder wallpaper in the nested session (ADR-0016, gate P3 indication).
#   Phase 1: a 5 s carousel of photos runs for 65 s with Reduce Motion off; the shell logs one line per fade ("wallpaper fade
#            ... frames= fast= slow= max="), this script totals them (the adaptive fade as it ships).
#   Phase 2: the full fade (adaptation off through `wallpaper fade full`) over four solid-colour pictures: the desktop is
#            captured about every 0.4 s and, for the changes 1, 2, 3 and 4 in a row, a capture in the middle of the fade must be
#            a BLEND of the old and the new colour (tests/visual/fade_blend.py). A hard cut, such as an incoming picture that
#            fades in underneath the opaque old one, has none and fails. Also: no capture is blank.
# Nested numbers are an indication only (the nested stack renders through the owner's compositor); P3 is an owner L2 run.
# Usage (bare command): tests/visual/wallpaper-fade.sh
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics/set1" "$pics/solid"
gen() { [[ -f $pics/$1 ]] || ffmpeg -loglevel error -y -f lavfi -i "$2" -frames:v 1 -q:v 3 "$pics/$1"; }
gen set1/1.jpg "gradients=s=1920x1080:seed=11:n=3:speed=0"
gen set1/2.jpg "mandelbrot=size=1920x1080:start_scale=2"
gen set1/3.jpg "testsrc=size=1920x1080"
gen set1/4.jpg "gradients=s=1920x1080:seed=5:n=5:speed=0"
colors=("#ff0000" "#00ff00" "#0000ff" "#ffff00")
for i in 1 2 3 4; do
  [[ -f $pics/solid/$i.png ]] || magick -size 1920x1080 "xc:${colors[$((i - 1))]}" "$pics/solid/$i.png"
done

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

check "the blend analysis tells a crossfade from a hard cut (selftest)" python3 -I "$VS_HERE/fade_blend.py" --selftest

vs_session
vs_reset
vs_ipc controlcenter reduceMotion false >/dev/null
cfg=$VS_DEV/config/grassfield.json
use_folder() { # folder
  printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"folder","path":"%s","fit":"fill","interval":"5s","shuffle":false}}\n' "$1" > "$cfg.new"
  mv "$cfg.new" "$cfg"
}

# Phase 1, no grabs (they load the compositor): 65 s of carousel, then the totals of the fade lines.
use_folder "$pics/set1"
sleep 65
grep "wallpaper fade" "$VS_DEV/shell.log" | cut -c1-200 | tee "$VS_DEV/fade-log.txt"
n=$(grep -c "wallpaper fade" "$VS_DEV/shell.log" || true)
echo "fades logged: $n"
check "the carousel changed pictures (at least 8 fade lines)" test "$n" -ge 8
frames=$(grep "wallpaper fade" "$VS_DEV/shell.log" | sed -n 's/.* frames=\([0-9]*\) .*/\1/p' | awk '{s+=$1} END {print s+0}')
slow=$(grep "wallpaper fade" "$VS_DEV/shell.log" | sed -n 's/.* slow=\([0-9]*\) .*/\1/p' | awk '{s+=$1} END {print s+0}')
fast=$(grep "wallpaper fade" "$VS_DEV/shell.log" | sed -n 's/.* fast=\([0-9]*\) .*/\1/p' | awk '{s+=$1} END {print s+0}')
echo "frames during fades: $frames, within 17.7 ms: $fast, over 33 ms: $slow"
awk -v f="$frames" -v s="$slow" -v q="$fast" 'BEGIN {printf "within 17.7 ms: %.1f %%, over 33 ms: %.1f %%\n", (f > 0 ? 100 * q / f : 0), (f > 0 ? 100 * s / f : 0)}'
full=$(grep "wallpaper fade" "$VS_DEV/shell.log" | grep -c "ms=1000" || true)
echo "full-length (1000 ms) fades: $full of $n, the rest were short or plain switches after dropped frames"

# Phase 2: the full fade over solid colours, captured every ~0.4 s for 45 s: the changes must be blends.
vs_ipc wallpaper fade full >/dev/null
use_folder "$pics/solid"
sleep 4
: > "$VS_DEV/fade-frames.txt"
blank=0
start=$(date +%s.%N)
for i in $(seq 1 90); do
  "$VS_ROOT/scripts/dev/shot.sh" "fade-$i" "$VS_OUTPUT" >/dev/null
  rgb=$(magick "$VS_DEV/shots/fade-$i.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info:)
  echo "$rgb" >> "$VS_DEV/fade-frames.txt"
  [[ $(date +%s.%N | awk -v s="$start" '{print ($1 - s) > 45}') == 1 ]] && break
done
captured=$(wc -l < "$VS_DEV/fade-frames.txt")
echo "captures: $captured in 45 s"
python3 -I "$VS_HERE/fade_blend.py" "$VS_DEV/fade-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0 | tee "$VS_DEV/fade-blend.txt"
check "every change of four in a row is a blend of the old and the new picture" python3 -I "$VS_HERE/fade_blend.py" "$VS_DEV/fade-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0
blank=$(awk '$1 + $2 + $3 < 15 {n++} END {print n + 0}' "$VS_DEV/fade-frames.txt")
check "no blank capture during the carousel ($captured captures, $blank blank)" test "$blank" = 0
vs_ipc wallpaper fade adaptive >/dev/null
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
