#!/usr/bin/env bash
# Every kind of wallpaper through the ONE two-slot model (ADR-0016, review finding): the Grassfield artwork, a solid colour and a
# picture, in every transition between two different contents, plus a change to a file that FAILS from each kind. The
# desktop is captured about every 0.5 s around each change; every capture must be the outgoing content, the incoming content
# or a blend of the two (tests/visual/fade_blend.py --between): never a third thing (the artwork showing through a colour, the
# bare window), and a failing file leaves the outgoing content on screen.
# Usage (bare command): tests/visual/wallpaper-transitions.sh      Captures: .dev/transitions/<from>-<to>.txt
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics/solid"
colors=("#ff0000" "#00ff00" "#0000ff" "#ffff00")
for i in 1 2 3 4; do
  [[ -f $pics/solid/$i.png ]] || magick -size 1920x1080 "xc:${colors[$((i - 1))]}" "$pics/solid/$i.png"
done
printf 'this is not a picture\n' > "$pics/garbage.jpg"
out=$VS_DEV/transitions
mkdir -p "$out"

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

# A wallpaper by name: art, red (a colour), green (a picture), blue (a colour), yellow (a picture), garbage (a failing file).
apply() {
  case $1 in
    art) w='{"source":"builtin"}' ;;
    red) w='{"source":"color","color":"#ff0000"}' ;;
    blue) w='{"source":"color","color":"#0000ff"}' ;;
    green) w=$(printf '{"source":"file","path":"%s","fit":"fill"}' "$pics/solid/2.png") ;;
    yellow) w=$(printf '{"source":"file","path":"%s","fit":"fill"}' "$pics/solid/4.png") ;;
    garbage) w=$(printf '{"source":"file","path":"%s","fit":"fill"}' "$pics/garbage.jpg") ;;
  esac
  printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":%s}\n' "$w" > "$cfg.new"
  mv "$cfg.new" "$cfg"
}

near() { # "r g b" "r g b": within 12 per channel (a prepared JPEG is not exact)
  awk -v a="$1" -v b="$2" 'BEGIN {split(a, x, " "); split(b, y, " "); for (i = 1; i <= 3; i++) {d = x[i] - y[i]; if (d < 0) d = -d; if (d > 12) exit 1} exit 0}'
}
color_now() { # "r g b" of the middle of the desktop right now
  "$VS_ROOT/scripts/dev/shot.sh" cur "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/cur.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info:
}

rgb_of() { # name -> "r,g,b" of the content on screen when it is stable
  apply "$1"
  # Stable: two captures 1.5 s apart agree (a slow machine takes seconds to prepare and fade in a picture).
  local prev="" cur="" i
  sleep 4
  for i in $(seq 1 30); do
    cur=$(color_now)
    near "$cur" "${prev:-999 999 999}" && break
    prev=$cur
    sleep 1.5
  done
  echo "${cur// /,}"
}

ref_art=$(rgb_of art)
ref_red=$(rgb_of red)
ref_green=$(rgb_of green)
ref_blue=$(rgb_of blue)
ref_yellow=$(rgb_of yellow)
echo "references: art $ref_art red $ref_red green $ref_green blue $ref_blue yellow $ref_yellow"
declare -A ref=([art]=$ref_art [red]=$ref_red [green]=$ref_green [blue]=$ref_blue [yellow]=$ref_yellow)

transition() { # from to final(to|from)
  local from=$1 to=$2 final=${3:-to} file=$out/$1-$2.txt
  apply "$from"
  # The outgoing content must be on screen and settled before the change (a slow machine takes seconds to prepare a picture).
  SECONDS=0
  until near "$(color_now)" "${ref[$from]//,/ }" || ((SECONDS > 40)); do sleep 0.5; done
  sleep 1
  : > "$file"
  ( sleep 0.7; apply "$to" ) &
  local changer=$!
  SECONDS=0
  local n=0
  # At least 7 s and 6 captures (a capture can take a second while a picture is prepared), at most 25 s.
  while { ((SECONDS < 7)) || ((n < 6)); } && ((SECONDS < 25)); do
    n=$((n + 1))
    "$VS_ROOT/scripts/dev/shot.sh" tr "$VS_OUTPUT" >/dev/null
    magick "$VS_DEV/shots/tr.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]\n' info: >> "$file"
  done
  wait "$changer"
  local target=$to
  [[ $to == garbage ]] && target=$from
  check "$from -> $to: only the two and their blends show, the last capture is the $final content" \
    python3 -I "$VS_HERE/fade_blend.py" --between "$file" "${ref[$from]}" "${ref[$target]}" "$final"
}

# Different contents, every kind to every kind (the same content twice is not a change).
transition art red
transition art green
transition red art
transition red green
transition green art
transition green red
transition red blue
transition green yellow
# A file that fails keeps whatever is on screen, from each kind.
transition art garbage from
transition red garbage from
transition green garbage from

check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
