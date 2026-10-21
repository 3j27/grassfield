#!/usr/bin/env bash
# Menu bar legibility over user wallpapers (ADR-0016 section 7, gate A2): generated worst-case pictures go through the real
# path (grassfield.json -> shell -> grassfield-wallpaper -> strip statistics -> BarTone). The bar must end with a tone that
# reaches 4.5:1 or, when no tone can, with the frosted band on that output. Pictures are generated under .dev, never committed.
# Usage (bare command): tests/visual/wallpaper-legibility.sh      Captures: $VS_SHOTS/legibility-*.en.png
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-a2
mkdir -p "$pics"
magick -size 1920x1080 xc:black "$pics/dark.png"
magick -size 1920x1080 xc:white "$pics/light.png"
magick -size 1920x1080 xc:black -fill white -draw "rectangle 0,0 959,1079" "$pics/split.png"
magick -size 1920x1080 xc:black -fill white -draw "rectangle 0,0 1919,11" "$pics/horizon.png"
# A threshold wallpaper: luminance 0.17, the crossover of the two tones (menubar.md).
magick -size 1920x1080 xc:'#767676' "$pics/threshold.png"
# Large-scale blocks of extreme luminance.
magick -size 30x17 xc: +noise Random -threshold 50% -scale 6400% -crop 1920x1080+0+0 +repage "$pics/blocks.png"
# Large-scale noise (a photo-like picture).
magick -size 24x14 xc: +noise Random -colorspace Gray -resize 1920x1080! -blur 0x20 "$pics/photolike.png"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

vs_session
vs_reset
cfg=$VS_DEV/config/grassfield.json

use() { # file
  jq --arg p "$pics/$1" '.wallpaper = {source: "file", path: $p, fit: "fill"}' "$cfg" > "$cfg.new" 2>/dev/null || printf '{"version":1,"wallpaper":{"source":"file","path":"%s","fit":"fill"}}\n' "$pics/$1" > "$cfg.new"
  mv "$cfg.new" "$cfg"
  vs_sleep 4
}

status() { vs_ipc bartone status; }
field() { # output field -> value
  status | jq -r --arg o "$VS_OUTPUT" --arg f "$1" '.[$o][$f]'
}

for case in dark:light:false light:dark:false split:any:true horizon:any:true; do
  IFS=: read -r name tone assist <<<"$case"
  use "$name.png"
  got_tone=$(field tone)
  got_assist=$(field assist)
  echo "$name: tone=$got_tone assist=$got_assist white=$(field white) black=$(field black)"
  check "$name: assist=$assist" test "$got_assist" = "$assist"
  [[ $tone == any ]] || check "$name: tone=$tone" test "$got_tone" = "$tone"
  vs_capture "legibility-$name" >/dev/null
  magick "$VS_SHOTS/legibility-$name.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/legibility-$name-bar.$VS_LANG.png"
done

# The rule for every picture: the tone reaches 4.5:1, or the band is on.
for name in threshold blocks photolike; do
  use "$name.png"
  w=$(field white)
  b=$(field black)
  a=$(field assist)
  t=$(field tone)
  echo "$name: tone=$t assist=$a white=$w black=$b"
  check "$name: legible or assisted" awk -v w="$w" -v b="$b" -v a="$a" 'BEGIN {best = (w > b ? w : b); exit !(best >= 4.5 || a == "true")}'
  vs_capture "legibility-$name" >/dev/null
  magick "$VS_SHOTS/legibility-$name.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/legibility-$name-bar.$VS_LANG.png"
done

check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
