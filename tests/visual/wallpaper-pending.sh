#!/usr/bin/env bash
# Changes that arrive faster than the picture decodes (ADR-0016, review finding): the picture on screen must stay until the
# next one is Ready, and a newer change replaces a pending one without touching what is shown. The dev hook `wallpaper
# loadDelay 2500` starts every decode 2.5 s late; four solid-colour pictures are switched 0.3 s apart while the desktop is
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

near() { # "r g b" "r g b": within 12 per channel (a prepared JPEG is not exact)
  awk -v a="$1" -v b="$2" 'BEGIN {split(a, x, " "); split(b, y, " "); for (i = 1; i <= 3; i++) {d = x[i] - y[i]; if (d < 0) d = -d; if (d > 12) exit 1} exit 0}'
}
color_now() { # "r g b" of the middle of the desktop right now
  "$VS_ROOT/scripts/dev/shot.sh" cur "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/cur.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info:
}
wait_color() { # picture number, its colour: poll until it is on screen (the machine may be slow), at most 40 s
  SECONDS=0
  while ((SECONDS < 40)); do
    near "$(color_now)" "$2" && return 0
    sleep 0.5
  done
  echo "the colour $2 of picture $1 never showed" >&2
  return 1
}

# Warm up without the hook: every picture is prepared (the helper's cache answers at once afterwards) and picture 1 is shown.
declare -A pure=([1]="255 0 0" [2]="0 255 0" [3]="0 0 255" [4]="255 255 0")
for i in 2 3 4 1; do
  use "$i"
  wait_color "$i" "${pure[$i]}"
done
check "the delay hook is accepted" test "$(vs_ipc wallpaper loadDelay 2500)" = ok

# The captures are only taken during the run (a colour read takes as long as a capture); each carries the time it was taken.
rm -f "$VS_DEV"/shots/pending-*.png
: > "$VS_DEV/pending-times.txt"
delayed_before=$(grep -c "decode of the next picture delayed" "$VS_DEV/shell.log" || true)
grab() {
  "$VS_ROOT/scripts/dev/shot.sh" "pending-$1" "$VS_OUTPUT" >/dev/null
  echo "$1 $(date +%s.%N)" >> "$VS_DEV/pending-times.txt"
}
grab 0
# Three changes 0.4 s apart (each faster than the 2.5 s decode), then the capture goes on while the pictures settle.
change_file=$VS_DEV/pending-change.txt
(
  sleep 0.2
  date +%s.%N > "$change_file"
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
# A slow machine: go on (up to 40 s) until the last picture has settled.
while ((SECONDS < 40)) && ! near "$(color_now)" "255 255 0"; do
  grab "$n"
  n=$((n + 1))
done
grab "$n"
wait "$changer"
: > "$VS_DEV/pending-frames.txt"
: > "$VS_DEV/pending-early.txt"
t_change=$(cat "$change_file")
while read -r i t; do
  rgb=$(magick "$VS_DEV/shots/pending-$i.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info:)
  echo "$rgb" >> "$VS_DEV/pending-frames.txt"
  # Captures taken between 0.6 s (the debounce and the preparation of the first change) and 3.0 s after the first change:
  # with the decode delayed by 2.5 s the new picture cannot be there yet, so they are still the old colour (red).
  if awk -v t="$t" -v c="$t_change" 'BEGIN {exit !(t - c > 0.6 && t - c < 3.0)}'; then
    echo "$rgb" >> "$VS_DEV/pending-early.txt"
  fi
done < "$VS_DEV/pending-times.txt"
echo "captures: $(wc -l < "$VS_DEV/pending-frames.txt"), early (still delayed): $(wc -l < "$VS_DEV/pending-early.txt")"
delayed_after=$(grep -c "decode of the next picture delayed" "$VS_DEV/shell.log" || true)
check "the hook delayed the changes (the shell logged $((delayed_after - delayed_before)) delayed decode(s), at least 2 expected)" test "$((delayed_after - delayed_before))" -ge 2
check "a capture was taken while the first change was still delayed, so the test cannot pass vacuously" test "$(wc -l < "$VS_DEV/pending-early.txt")" -ge 1
early_not_red=$(while read -r c; do near "$c" "255 0 0" || echo "$c"; done < "$VS_DEV/pending-early.txt" | wc -l)
check "the delayed new colour did not show early: those captures are still red ($early_not_red are not)" test "$early_not_red" = 0
check "no capture shows the artwork or the bare window between the pictures" python3 -I "$VS_HERE/fade_blend.py" --only-pictures "$VS_DEV/pending-frames.txt" 255,0,0 0,255,0 0,0,255 255,255,0
check "the last picture ends on screen (yellow)" near "$(tail -1 "$VS_DEV/pending-frames.txt")" "255 255 0"
vs_ipc wallpaper loadDelay 0 >/dev/null
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
