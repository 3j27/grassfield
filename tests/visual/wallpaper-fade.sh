#!/usr/bin/env bash
# Crossfade of a folder wallpaper in the nested session (ADR-0016): the desktop over four solid-colour pictures, a 5 s
# carousel with Reduce Motion off, captured about every 0.4 s for 45 s. For the changes 1, 2, 3 and 4 in a row (and the
# following ones) a capture in the middle of the fade must be a BLEND of the old and the new colour (tests/visual/fade_blend.py).
# A hard cut, such as an incoming picture that fades in underneath the opaque old one, has none and fails. Also: no capture is
# blank. This checks WHAT is shown, not how smoothly: the frame timing of the fade (gate P3) is measured on real hardware
# (owner L2); the nested compositor is the bottleneck here and its numbers say nothing about the shell.
# Usage (bare command): tests/visual/wallpaper-fade.sh
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics/solid"
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
printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"folder","path":"%s","fit":"fill","interval":"5s","shuffle":false}}\n' "$pics/solid" > "$cfg.new"
mv "$cfg.new" "$cfg"
sleep 4

: > "$VS_DEV/fade-frames.txt"
SECONDS=0
while ((SECONDS < 45)); do
  "$VS_ROOT/scripts/dev/shot.sh" fade-frame "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/fade-frame.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]\n' info: >> "$VS_DEV/fade-frames.txt"
done
captured=$(wc -l < "$VS_DEV/fade-frames.txt")
echo "captures: $captured in 45 s"
python3 -I "$VS_HERE/fade_blend.py" "$VS_DEV/fade-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0 | tee "$VS_DEV/fade-blend.txt" || true
check "every change of four in a row is a blend of the old and the new picture" python3 -I "$VS_HERE/fade_blend.py" "$VS_DEV/fade-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0
check "nothing but the pictures and their blends shows (no artwork, no bare window)" python3 -I "$VS_HERE/fade_blend.py" --only-pictures "$VS_DEV/fade-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0
blank=$(awk '$1 + $2 + $3 < 15 {n++} END {print n + 0}' "$VS_DEV/fade-frames.txt")
check "no blank capture during the carousel ($captured captures, $blank blank)" test "$blank" = 0
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
