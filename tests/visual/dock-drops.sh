#!/usr/bin/env bash
# Real GTK4 drags onto Dock tiles in the nested session (tests/visual/fixtures/dragsrc.py is the drag source, a Wayland client
# offering text/uri-list; the pointer is a virtual pointer on the nested compositor only; every app goes through isolated.sh).
# Two test apps are running: "gfdrop" (opens text/plain and folders) and "gfdir" (folders only); opening appends the paths to a
# log file. Checks: the tile highlights while hovering only a file it can open (a refused file or a folder with an extension
# is judged by its real type), the drop opens exactly the accepted files, and a refused drop is not a performed drop for the source (no "drop-performed").
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-drops.sh
# Output: .dev/visual/dock-drops/*.png (captures while hovering) and a table on stdout. Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"

out=$VS_STATE/dock-drops
box=$out/files
log=$out/opened.log
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${ptr_pid:-} ]] && kill "$ptr_pid" 2>/dev/null || true
  # Clients of the test (foot windows outlive the nested compositor): close them first.
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

rm -rf "$out"
mkdir -p "$out" "$box" "$VS_DEV/share/applications" "$VS_DEV/share/gfmotion"
printf 'hello\n' > "$box/a.txt"
printf 'hello\n' > "$box/b.txt"
printf '#!/bin/sh\necho hi\n' > "$box/run"
printf '\x00\x01\x02\x03binary\n' > "$box/bin.dat"
printf 'x\n' > "$box/pic.png"
mkdir "$box/Photos.png" "$box/Folder"
magick -size 64x64 xc:'#ff00ff' "$VS_DEV/share/gfmotion/a.png"
magick -size 64x64 xc:'#00ffff' "$VS_DEV/share/gfmotion/b.png"
# %F: one launch with all files; the log gets one line per path.
printf '[Desktop Entry]\nType=Application\nName=GF Drop\nExec=sh -c '"'"'for f in "$@"; do echo "$f" >> "%s"; done'"'"' sh %%F\nMimeType=text/plain;inode/directory;\nIcon=%s\n' "$log" "$VS_DEV/share/gfmotion/a.png" > "$VS_DEV/share/applications/gfdrop.desktop"
printf '[Desktop Entry]\nType=Application\nName=GF Dir\nExec=sh -c '"'"'for f in "$@"; do echo "$f" >> "%s"; done'"'"' sh %%F\nMimeType=inode/directory;\nIcon=%s\n' "$log" "$VS_DEV/share/gfmotion/b.png" > "$VS_DEV/share/applications/gfdir.desktop"
: > "$log"

vs_session en
vs_reset dark 0.25
sock=$(vs_nested_wayland)
origin=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.x) \(.y)"')
ox=${origin% *}
oy=${origin#* }

echo "windows at start: $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | .class] | join(",")')"
vs_spawn foot --app-id gfdrop
vs_sleep 1.5
vs_spawn foot --app-id gfdir
vs_sleep 3

# Tile centre from a fresh capture (the test icons are pure magenta and cyan; the source window adds a tile of its own, so the
# tiles are located after it is up).
centre() { # magenta|cyan -> "x y"
  python3 -I - "$VS_DEV/shots/dock-drops-tiles.png" "$1" <<'PY'
import subprocess, sys
png, colour = sys.argv[1:3]
w, h = 1920, 1080
data = subprocess.run(["magick", png, "-crop", "1000x160+460+920", "+repage", "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
cw = 1000
xs, ys = [], []
for i in range(0, len(data), 3):
    r, g, b = data[i], data[i + 1], data[i + 2]
    hit = (r > 200 and b > 200 and g < 60) if colour == "magenta" else (g > 200 and b > 200 and r < 60)
    if hit:
        p = i // 3
        xs.append(p % cw)
        ys.append(p // cw)
print(460 + (min(xs) + max(xs)) // 2, 920 + (min(ys) + max(ys)) // 2)
PY
}

fail=0
# drag NAME COLOUR HOLD_MS PATH...: a source window with PATH..., dragged onto the tile, held HOLD_MS over it, released.
# Prints the source's drag events; $out/NAME.png is a capture taken while the pointer is over the tile.
drag() {
  local name=$1 colour=$2 hold=$3 tx ty
  shift 3
  local slog=$out/$name.src.log bus="" sx sy at i
  [[ -f $VS_DEV/bus.address ]] && bus=$(<"$VS_DEV/bus.address")
  : > "$slog"
  : > "$log"
  "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
    env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="${bus:-}" LC_ALL=en_US.UTF-8 GSK_RENDERER=cairo GDK_BACKEND=wayland \
    python3 -I "$VS_HERE/fixtures/dragsrc.py" 12 "$@" >/dev/null 2>"$slog" </dev/null &
  vs_track "$!"
  at=""
  for i in $(seq 1 40); do
    at=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "gfdragsrc") | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -n 1)
    [[ -n $at ]] && break
    sleep 0.25
  done
  [[ -n $at ]] || { echo "dock-drops: the drag source window did not appear" >&2; fail=1; return; }
  read -r wx wy ww wh <<<"$at"
  echo "[$name] windows: $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | .class] | join(",")')"
  sleep 1.5
  "$VS_ROOT/scripts/dev/shot.sh" dock-drops-tiles "$VS_OUTPUT" >/dev/null
  read -r tx ty <<<"$(centre "$colour")"
  sx=$(( wx - ox + ww / 2 ))
  sy=$(( wy - oy + wh / 2 ))
  sleep 0.5
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs "$sx" "$sy" sleep 200 down sleep 200 drag "$tx" "$ty" sleep "$hold" up sleep 400 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
  ptr_pid=$!
  sleep 1.3
  "$VS_ROOT/scripts/dev/shot.sh" "dock-drops-$name" "$VS_OUTPUT" >/dev/null
  cp "$VS_DEV/shots/dock-drops-$name.png" "$out/$name.png"
  wait "$ptr_pid" || true
  ptr_pid=""
  sleep 1
  local pid
  for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "gfdragsrc") | .pid'); do
    dev_may_signal "$pid" && kill "$pid" || true
  done
  sleep 1
}

# verdict NAME EXPECT(open|refuse) PATH...: what the log and the source say. The source (GTK4) is told by the compositor: an
# accepted drop shows "drop-performed" then "dnd-finished"; a drop the Dock refused (the drag was never accepted by the tile) ends
# without "drop-performed" (the source sees no successful drop), and a drop no target takes is a "cancel".
opened() { grep -cxF "$1" "$log" || true; }
verdict() {
  local name=$1 want=$2 p performed ended got=0
  shift 2
  performed=$(grep -c 'drop-performed' "$out/$name.src.log" || true)
  ended=$(grep -cE 'dnd-finished|gdk-cancel|cancel reason' "$out/$name.src.log" || true)
  for p in "$@"; do got=$(( got + $(opened "$p") )); done
  if [[ $want == open ]]; then
    if (( got == $# && performed == 1 )); then printf '%-34s PASS opened %d, source saw the drop performed\n' "$name" "$got"; else printf '%-34s FAIL opened %d of %d, drop-performed %s\n' "$name" "$got" "$#" "$performed"; fail=1; fi
  else
    if (( got == 0 && performed == 0 && ended >= 1 )); then printf '%-34s PASS refused: nothing opened, the source saw no drop performed\n' "$name"; else printf '%-34s FAIL opened %d, drop-performed %s, ended %s\n' "$name" "$got" "$performed" "$ended"; fail=1; fi
  fi
}

: > "$log"
drag txt-on-text magenta 1500 "$box/a.txt"
verdict txt-on-text open "$box/a.txt"
drag two-on-text magenta 1500 "$box/a.txt" "$box/b.txt"
verdict two-on-text open "$box/a.txt" "$box/b.txt"
drag script-on-text magenta 1500 "$box/run"
verdict script-on-text open "$box/run"
drag folder-on-text magenta 1500 "$box/Folder"
verdict folder-on-text open "$box/Folder"
drag dotfolder-on-dir cyan 1500 "$box/Photos.png"
verdict dotfolder-on-dir open "$box/Photos.png"
drag png-on-dir cyan 1500 "$box/pic.png"
verdict png-on-dir refuse "$box/pic.png"
drag bin-on-text magenta 1500 "$box/bin.dat"
verdict bin-on-text refuse "$box/bin.dat"
drag txt-on-dir cyan 1500 "$box/a.txt"
verdict txt-on-dir refuse "$box/a.txt"
echo "captures while hovering: $out/*.png (accepted drops highlight the tile, refused ones do not)"
exit $fail
