#!/usr/bin/env bash
# Changes that arrive faster than the picture decodes (ADR-0016, review finding): the picture on screen must stay until the
# next one is Ready, and a newer change replaces a pending one without touching what is shown. The dev hook `wallpaper
# loadDelay 900` starts every decode 0.9 s late; four solid-colour pictures are switched 0.3 s apart while the desktop is
# captured; every capture must be a picture or a blend of two pictures, never the artwork or the bare window colour.
# Usage (bare command): tests/visual/wallpaper-pending.sh
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

vs_session
vs_reset
vs_ipc controlcenter reduceMotion false >/dev/null
cfg=$VS_DEV/config/grassfield.json
use() { # picture number
  printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"file","path":"%s","fit":"fill"}}\n' "$pics/solid/$1.png" > "$cfg.new"
  mv "$cfg.new" "$cfg"
}

# Warm up without the hook: every picture is prepared (the helper's cache answers at once afterwards) and picture 1 is shown.
for i in 2 3 4 1; do
  use "$i"
  sleep 3
done
check "the delay hook is accepted" test "$(vs_ipc wallpaper loadDelay 900)" = ok

: > "$VS_DEV/pending-frames.txt"
grab() {
  "$VS_ROOT/scripts/dev/shot.sh" "pending-$1" "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/pending-$1.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]\n' info: >> "$VS_DEV/pending-frames.txt"
}
grab 0
# Three changes 0.3 s apart (each faster than the 0.9 s decode), then the capture goes on while the pictures settle.
(
  sleep 0.2
  use 2
  sleep 0.4
  use 3
  sleep 0.4
  use 4
) &
changer=$!
SECONDS=0
n=1
while ((SECONDS < 7)); do
  grab "$n"
  n=$((n + 1))
done
wait "$changer"
echo "captures: $(wc -l < "$VS_DEV/pending-frames.txt")"
check "no capture shows the artwork or the bare window between the pictures" python3 -I "$VS_HERE/fade_blend.py" --only-pictures "$VS_DEV/pending-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0
check "the last picture ends on screen (yellow)" test "$(tail -1 "$VS_DEV/pending-frames.txt")" = "255 255 0"
vs_ipc wallpaper loadDelay 0 >/dev/null
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
