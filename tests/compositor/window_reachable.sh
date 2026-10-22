#!/usr/bin/env bash
# Every new window can be moved (macOS model: a window opens with its title bar below the menu bar, never under it or
# off the screen; a window taller than the free area is made to fit). Owner defect 2026-10-22: Spotify opened under the
# menu bar and could not be moved. Clients that ask for a size larger than the free area of GF-REF, or for its top-left
# corner (as an application restoring a stored geometry does):
#   wl-big     foot (Wayland), 1920x1080 pixels
#   x-big      Chromium on XWayland (Spotify is a CEF app on XWayland), 1920x1080 at GF-REF's origin
#   x-corner   Chromium on XWayland, 1000x700 at GF-REF's origin
#   wl-big-cr  Chromium on Wayland, 1920x1080
# For each, the window's top (its titlebar when grassfield-compositor draws one) must be at or below the menu bar's
# reserved strip, its left/right edges on the output, and its bottom no lower than the output.
# Usage (bare command, nested session of this tree running): tests/compositor/window_reachable.sh
# Logs: .dev/window-reachable/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=GF-REF
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
chromium=/usr/lib/chromium/chromium

run=$dev/window-reachable/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
fail=0
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; else say "FAIL: $name"; fail=1; fi
}

pids=()
cleanup() { for p in "${pids[@]}"; do kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM

# The nested instance's own X display (never this shell's: it is the owner's).
nestctl dispatch "hl.dsp.exec_cmd(\"printf %s \\\"\$DISPLAY\\\" > $run/xdisplay\")" >>"$log" 2>&1
sleep 0.8
xdisplay=$(cat "$run/xdisplay" 2>/dev/null || true)
[[ $xdisplay == :* && $xdisplay != "${DISPLAY:-none}" ]] || { say "setup error: no nested X display (got '$xdisplay')"; exit 2; }

read -r mx my mw mh rtop rbottom < <(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.reserved[1]) \(.reserved[3])"')
plugin=0
nestctl -j grassfield 2>/dev/null | jq -e '.features | index("decorations")' >/dev/null 2>&1 && plugin=1
bar=$((plugin ? GF_TB_HEIGHT : 0))
say "GF-REF ${mw}x${mh} at $mx,$my, reserved top $rtop bottom $rbottom, plugin titlebar $bar px, X display $xdisplay"
nestctl dispatch "hl.dsp.focus({ monitor = \"$out\" })" >>"$log" 2>&1

spawn() { # name, then the command; Wayland clients get the nested socket, X11 clients only the nested X display
  local name=$1
  shift
  if [[ $name == x-* ]]; then
    # isolated.sh drops DISPLAY: the nested X display goes inside it, and no Wayland socket at all (an X11 client only).
    env -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name "reach-$name" \
      env -u WAYLAND_DISPLAY DISPLAY="$xdisplay" "$@" >>"$run/$name.out" 2>&1 </dev/null &
  else
    env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name "reach-$name" "$@" >>"$run/$name.out" 2>&1 </dev/null &
  fi
  pids+=("$!")
}
page() { printf 'data:text/html,<title>%s</title><body style="background:%%23345">%s</body>' "$1" "$1"; }
geometry() { # title -> "x y w h"
  nestctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'
}
wait_window() { # title -> geometry once mapped (20 s)
  local i g
  for i in $(seq 1 100); do
    g=$(geometry "$1")
    [[ -n $g ]] && { sleep 1; geometry "$1"; return 0; }
    sleep 0.2
  done
  return 1
}
reachable() { # name title
  local g x y w h top
  g=$(wait_window "$2") || { say "FAIL: $1: no window titled $2 appeared"; fail=1; return; }
  read -r x y w h <<<"$g"
  top=$((y - bar))
  say "$1: surface ${w}x${h} at $x,$y (top with titlebar $top)"
  check "$1: the top is at or below the menu bar ($top >= $((my + rtop)))" test "$top" -ge $((my + rtop))
  check "$1: left and right edges on the output ($x..$((x + w)) within $mx..$((mx + mw)))" test "$x" -ge "$mx" -a $((x + w)) -le $((mx + mw))
  check "$1: the bottom is on the output ($((y + h)) <= $((my + mh)))" test $((y + h)) -le $((my + mh))
  "$root/scripts/dev/shot.sh" "reach-$1" "$out" >>"$log" 2>&1 && cp "$dev/shots/reach-$1.png" "$run/" 2>/dev/null
  nestctl dispatch "hl.dsp.window.close({ window = \"title:$2\" })" >>"$log" 2>&1
  sleep 0.5
}

spawn wl-big foot -T reach-wl-big -w 1920x1080 sh -c 'exec sleep 100000'
reachable wl-big reach-wl-big
if [[ -x $chromium ]]; then
  spawn x-big "$chromium" --ozone-platform=x11 --user-data-dir="$run/x-big-profile" --no-first-run --no-default-browser-check \
    --password-store=basic --disable-sync --window-size=1920,1080 --window-position="$mx,$my" --app="$(page reach-x-big)"
  reachable x-big reach-x-big
  spawn x-corner "$chromium" --ozone-platform=x11 --user-data-dir="$run/x-corner-profile" --no-first-run --no-default-browser-check \
    --password-store=basic --disable-sync --window-size=1000,700 --window-position="$mx,$my" --app="$(page reach-x-corner)"
  reachable x-corner reach-x-corner
  spawn wl-big-cr "$chromium" --ozone-platform=wayland --user-data-dir="$run/wl-big-profile" --no-first-run --no-default-browser-check \
    --password-store=basic --disable-sync --window-size=1920,1080 --app="$(page reach-wl-big-cr)"
  reachable wl-big-cr reach-wl-big-cr
else
  say "SKIP: Chromium cases ($chromium not installed)"
fi
exit $fail
