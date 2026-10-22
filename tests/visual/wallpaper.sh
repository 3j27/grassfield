#!/usr/bin/env bash
# Wallpaper end to end in the nested session (ADR-0016): the desktop before and after a change made in Settings >
# Wallpaper, the choice kept in grassfield.json, kept across a shell restart, and the idle cost of a still wallpaper.
# Test pictures are generated under .dev/wallpapers-e2e (never the owner's photos).
# Usage (bare command): tests/visual/wallpaper.sh        Captures: $VS_SHOTS/wallpaper-*.en.png
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics" "$pics/set1"
gen() { # name filter
  [[ -f $pics/$1 ]] || ffmpeg -loglevel error -y -f lavfi -i "$2" -frames:v 1 -q:v 3 "$pics/$1"
}
gen a.jpg "gradients=s=1920x1080:seed=3:n=4:speed=0"
gen b.jpg "mandelbrot=size=1920x1080"
gen c.jpg "testsrc2=size=1920x1080"
gen set1/1.jpg "gradients=s=1920x1080:seed=11:n=3:speed=0"
gen set1/2.jpg "mandelbrot=size=1920x1080:start_scale=2"
gen set1/3.jpg "testsrc=size=1920x1080"
export GRASSFIELD_PICTURES_DIR=$pics

fail=0
check() { # name command...   (the command is run; set -e must not end the script on a failed check)
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

vs_session
vs_reset
cfg=$VS_DEV/config/grassfield.json

vs_capture wallpaper-desktop-before >/dev/null
vs_spawn "$VS_DEV/build/grassfield-settings" --section=wallpaper
vs_wait_clients 1
vs_sleep 3
vs_capture wallpaper-settings-before

# The Pictures grid: the first tile applies a.jpg ("x y" of its centre on GF-REF, from the captures).
tile_x=${WP_TILE_X:-897}
tile_y=${WP_TILE_Y:-688}
vs_pointer abs "$tile_x" "$tile_y" sleep 300 click >/dev/null
vs_sleep 4
vs_capture wallpaper-settings-after
src=$(jq -r '.wallpaper.source // "none"' "$cfg" 2>/dev/null || echo none)
path=$(jq -r '.wallpaper.path // ""' "$cfg" 2>/dev/null || echo "")
check "the choice is written to grassfield.json (source=$src path=$path)" test "$src|$path" = "file|$pics/a.jpg"
st=$(jq -r '[.outputs[] | .state] | unique | join(",")' "$VS_DEV/config/wallpaper-state.json" 2>/dev/null || echo none)
check "the shell reports ready on every output (state=$st)" test "$st" = ready
check "no QML error in the shell log" test "$(grep -cE 'ERROR|TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0

# Persistence: a new shell shows the same picture (the file source is read again, the prepared copy comes from the cache).
vs_kill_clients
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop" >/dev/null
for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
vs_sleep 5
vs_capture wallpaper-desktop-after-restart
a=$(magick "$VS_SHOTS/wallpaper-desktop-after-restart.$VS_LANG.png" -crop 400x300+300+300 +repage -format '%#' info:)
b=$(magick "$VS_SHOTS/wallpaper-desktop-before.$VS_LANG.png" -crop 400x300+300+300 +repage -format '%#' info:)
check "the desktop differs from the artwork after the restart" test "$a" != "$b"

# Idle cost of a still picture against the artwork: CPU ticks of the shell over 30 s, after the startup work has settled.
cpu_of() { # seconds
  local pid t0 t1
  pid=$(dev_live_pid "$VS_DEV/shell.pid")
  t0=$(awk '{print $14+$15}' "/proc/$pid/stat")
  sleep "$1"
  t1=$(awk '{print $14+$15}' "/proc/$pid/stat")
  awk -v a="$t0" -v b="$t1" -v s="$1" 'BEGIN {printf "%.2f", (b-a)/100/s*100}'
}
sleep 15
cpu_pic=$(cpu_of 30)
echo "idle CPU of the shell with a still picture: $cpu_pic % of one core over 30 s"
jq '.wallpaper.source = "builtin"' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
sleep 15
cpu_art=$(cpu_of 30)
echo "idle CPU of the shell with the artwork: $cpu_art % of one core over 30 s"
# A margin of one point and an absolute ceiling: under load from other processes a 30 s window varies by a few tenths.
check "a still picture costs at most max(0.5 %, 3x the artwork) and stays under 2 % (picture $cpu_pic %, artwork $cpu_art %)" awk -v p="$cpu_pic" -v a="$cpu_art" 'BEGIN {m = 3 * a; if (m < 0.5) m = 0.5; exit !(p <= m && p < 2.0)}'

vs_kill_clients
exit $fail
