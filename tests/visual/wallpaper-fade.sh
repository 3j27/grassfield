#!/usr/bin/env bash
# Crossfade of a folder wallpaper in the nested session (ADR-0016): the desktop over solid-colour pictures. The fade is
# lengthened to 6 s by the dev hook (`wallpaper fadeLength`) and its progress is READ from the shell (`wallpaper progress`), so
# the timing of the captures does not depend on how fast the nested compositor grabs a frame. For each of 5 changes in a row
# (red, green, blue, yellow, red) the script waits for the fade to be 20-50 % done, reads the progress p0, captures, reads p1,
# and the captured colour must lie on the straight line between old + p0 * (new - old) and old + p1 * (new - old)
# (tests/visual/fade_mid.py). A hard cut, such as an incoming picture that fades in underneath the opaque old one, shows the old
# colour all along and fails. This checks WHAT is shown, not how smoothly: the frame timing of the fade (gate P3) is measured
# on real hardware (owner L2).
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

check "the blend prediction tells a crossfade from a hard cut (selftest)" python3 -I "$VS_HERE/fade_mid.py" --selftest

vs_session
vs_reset
vs_ipc controlcenter reduceMotion false >/dev/null
vs_ipc wallpaper fadeLength 6000 >/dev/null
cfg=$VS_DEV/config/grassfield.json

apply() { # picture number
  printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"file","path":"%s/solid/%s.png","fit":"fill"}}\n' "$pics" "$1" > "$cfg.new"
  mv "$cfg.new" "$cfg"
}
progress() { vs_ipc wallpaper progress "$VS_OUTPUT" | tr -d '[:space:]'; }
rgb_now() { # "r,g,b" of the middle of the desktop right now
  "$VS_ROOT/scripts/dev/shot.sh" fade-frame "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/fade-frame.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info:
}
between() { awk -v p="$1" -v lo="$2" -v hi="$3" 'BEGIN {exit !(p >= lo && p <= hi)}'; }
idle() { # waits for no fade running; fails after about 60 s
  local i p
  for i in $(seq 1 300); do
    p=$(progress)
    [[ $p == -1 ]] && return 0
    sleep 0.2
  done
  return 1
}

# The colour each picture shows once settled (a prepared JPEG is not exact), taken in the first round.
declare -A settled
declare -A nominal=([1]=255,0,0 [2]=0,255,0 [3]=0,0,255 [4]=255,255,0)
near_nominal() { # "r,g,b" picture number: within 40 of the picture's pure colour
  python3 -I -c 'import sys,math; a=[int(v) for v in sys.argv[1].split(",")]; b=[int(v) for v in sys.argv[2].split(",")]; sys.exit(0 if math.dist(a,b) < 40 else 1)' "$1" "${nominal[$2]}"
}
order=(1 2 3 4 1)
apply "${order[0]}"
# The first picture is on screen and the fade done: its colour is its pure colour (a prepared JPEG is not exact).
now=""
for i in $(seq 1 60); do
  now=$(rgb_now)
  near_nominal "$now" "${order[0]}" && [[ $(progress) == -1 ]] && break
  sleep 1
done
# The capture above can predate the end of the fade that the progress read after it no longer shows (it measured 230,10,11
# for 254,0,0, within the tolerance): the settled colour is measured as the loop below measures its ends, once idle.
idle || true
sleep 1
now=$(rgb_now)
near_nominal "$now" "${order[0]}" || { echo "FAIL: the first picture did not settle (shows $now)"; exit 1; }
settled[${order[0]}]=$now
echo "start: picture ${order[0]} shows ${settled[${order[0]}]}"

blends=0
changes=0
for ((k = 1; k < ${#order[@]}; k++)); do
  from=${order[k - 1]}
  to=${order[k]}
  apply "$to"
  # Wait (up to 40 s: a picture is prepared first) for the fade to be 20-50 % done.
  p0=""
  for i in $(seq 1 200); do
    p=$(progress)
    if [[ $p != -1 ]] && between "$p" 0.2 0.5; then p0=$p; break; fi
    if [[ $p != -1 ]] && ! between "$p" 0 0.5; then break; fi
    sleep 0.2
  done
  if [[ -z $p0 ]]; then
    echo "FAIL: change $from -> $to: no fade seen at 20-50 % (last progress ${p:-none})"
    fail=1
    idle || true
    continue
  fi
  now=$(rgb_now)
  p1=$(progress)
  changes=$((changes + 1))
  # The colour the new picture will show is only known after the first time it settled: measure it when this fade is over.
  idle || true
  sleep 1
  end=$(rgb_now)
  settled[$to]=$end
  near_nominal "$end" "$to" || { echo "FAIL: change $from -> $to ended on $end, not picture $to"; fail=1; continue; }
  echo "change $from -> $to: p0 $p0 capture $now p1 $p1 end $end (old ${settled[$from]})"
  if python3 -I "$VS_HERE/fade_mid.py" "${settled[$from]}" "$end" "$now" "$p0" "${p1/#-1/1}" > "$VS_DEV/fade-mid.txt"; then
    echo "PASS: change $from -> $to is a blend at progress $p0..$p1"
    blends=$((blends + 1))
  else
    echo "FAIL: change $from -> $to: $(cat "$VS_DEV/fade-mid.txt")"
    fail=1
  fi
done
check "every one of $changes changes in a row showed a blend in the middle of the fade ($blends)" test "$changes" -ge 4 -a "$blends" = "$changes"
vs_ipc wallpaper fadeLength 0 >/dev/null || true
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
