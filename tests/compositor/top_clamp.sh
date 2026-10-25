#!/usr/bin/env bash
# L1 nested scenario: a window's titlebar never goes under the menu bar (macOS; owner report from the 1.0.0-rc1 real
# session: Chromium dragged up until its tab strip was under the menu bar could not be grabbed again). Plugin: core and
# glue TopClamp (docs/specs/compositor.md FR56).
#
# Usage: tests/compositor/top_clamp.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin, the shell (its menu bar reserves the top strip of
# GF-REF) and the private bus (.dev/bus.address). Clients start through scripts/dev/isolated.sh on the private bus and
# the nested socket, offline (the discard port as their proxy, as third_party_chrome.sh); hyprctl only through
# scripts/nestctl (read-only, plus window moves); pointer input through scripts/dev/pointer.sh (nested only).
#
# The menu bar's bottom is GF-REF's top reserved area (hyprctl monitors). Each window is placed at (300, 300) and dragged
# up with the pointer kept BELOW the menu bar (a pointer on the menu bar would tile the window to fill the screen, FR47),
# grabbed low enough in its titlebar that its top would end under the menu bar:
#   P  foot (the plugin's titlebar, 32 px above the surface; the plugin moves the window itself):
#      P1 during the drag the titlebar never goes under the menu bar (sampled while the button is held);
#      P2 after the release the titlebar starts at the menu bar's bottom, and the window kept the pointer's x;
#      P3 it can be grabbed again: a drag down by 200 px moves it down by 200 px.
#   C  Chromium's browser window (client chrome: its own tab strip, Hyprland's interactive move from xdg_toplevel.move):
#      C0 while the button is held its top is under the menu bar (Hyprland's move has no hook; the pointer goes onto the
#         menu bar, which only the plugin's own titlebar drags take as a tiling place, FR47);
#      C1 after the release its top is at the menu bar's bottom (the clamp after Hyprland ended the drag);
#      C2 it can be grabbed again by its tab strip: a drag down moves it down.
#   R  foot placed with its titlebar under the menu bar (as an app or a script may place it), then resized from its
#      bottom edge (Hyprland's resize on the border; review of e0a3734: a resize that does not move the top edge must
#      never move or cut the window):
#      R0 the bottom edge was dragged (the window grew);
#      R1 its top did not move.
# The multi-output cases of the same review (stacked and bottom-aligned outputs) are unit cases (tests/TopClampTest.cpp):
# the nested session has one output.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${TC_OUTPUT:-GF-REF}

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "top_clamp: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "top_clamp: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "top_clamp: no private bus (.dev/bus.address; nested-up.sh starts it)" >&2; exit 2 ;;
esac

work=$dev/top-clamp
rm -rf "$work"
mkdir -p "$work"
for n in foot chromium; do rm -rf "$dev/isolated/tc-$n"; done
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
dead_proxy=127.0.0.1:9
client_run() { # <name> <command...>: on the nested socket and the private bus, isolated and offline
  local name=$1 p=http://$dead_proxy
  shift
  http_proxy=$p https_proxy=$p all_proxy=$p HTTP_PROXY=$p HTTPS_PROXY=$p ALL_PROXY=$p no_proxy='' NO_PROXY='' \
    WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus GDK_BACKEND=wayland \
    setsid "$root/scripts/dev/isolated.sh" --name "tc-$name" -- "$@" >>"$log" 2>&1 </dev/null &
  echo $!
}

read -r mon_x mon_y mon_w mon_h top_reserved < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.reserved[1])"')
[[ -n ${mon_w:-} ]] || { echo "top_clamp: output $out not found" >&2; exit 2; }
ctl -j plugin list | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null \
  || { echo "top_clamp: the plugin is not loaded" >&2; exit 2; }
((top_reserved > 0)) || { echo "top_clamp: no menu bar on $out (top reserved area $top_reserved; is the shell running?)" >&2; exit 2; }
mb=$top_reserved # the menu bar's bottom, output px

pids=()
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 & # anchor pointer (as minimize.sh)
pids+=($!)
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
}
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }
client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class | test(\$c)) | $2" | head -1; }
geom() { # <class regex> -> "x y w h" (output px)
  ctl clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class | test($c)) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"' | head -1
}
wait_mapped() { local i; for i in $(seq 1 "${2:-60}"); do [[ -n $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
place() { # <class regex> <x> <y>
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$(client "$1" .address)' })" >>"$log" 2>&1
  sleep 0.8
}
# A drag with the left button: press at (x1, y1) after a fresh motion, glide to (x2, y2) in 20 steps, hold <hold> ms, release.
# In the background (not in a subshell: `wait "$bg"` needs it as this shell's child): the caller samples the geometry while
# the button is held, then waits.
drag_bg() { # <x1> <y1> <x2> <y2> <hold ms>
  pointer abs $((mon_w - 40)) $((mon_h / 2)) sleep 150 abs "$1" "$(($2 + 3))" sleep 120 abs "$1" "$2" sleep 200 down sleep 150 drag "$3" "$4" sleep "$5" up sleep 300 &
  bg=$!
}
# A click at (x, y) after a fresh motion (the window gets focus before its first drag).
click_at() { # <x> <y>
  pointer abs $((mon_w - 40)) $((mon_h / 2)) sleep 150 abs "$1" "$(($2 + 3))" sleep 120 abs "$1" "$2" sleep 200 click sleep 700
}

say "top_clamp: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}, menu bar bottom $mb px"

# ---- P: foot, the plugin's titlebar ----
say "P foot (the plugin's titlebar)"
p=$(client_run foot foot --window-size-pixels=700x400); pids+=("$p")
wait_mapped '^foot$' || { say "setup error: foot did not map"; exit 2; }
place '^foot$' 300 300
read -r x0 y0 _ _ < <(geom '^foot$')
band=32
grab_x=$((x0 + 350)) grab_y=$((y0 - 4))  # the titlebar's lowest rows: its top would end 28 px above the pointer
to_y=$((mb + 10))                          # the pointer stays below the menu bar
drag_bg "$grab_x" "$grab_y" "$grab_x" "$to_y" 1500
sleep 1.6
read -r _ ym _ _ < <(geom '^foot$')
wait "$bg"
sleep 0.4
read -r x1 y1 _ _ < <(geom '^foot$')
[[ -n ${ym:-} ]] && (( ym - band >= mb - 1 ))
check "P1 during the drag its titlebar stays below the menu bar" $? "titlebar top $((ym - band)) while held, menu bar bottom $mb (unclamped it would be $((to_y - band + 4)))"
(( y1 - band >= mb - 1 && y1 - band <= mb + 1 && x1 == x0 ))
check "P2 after the release its titlebar starts at the menu bar's bottom, x kept" $? "titlebar top $((y1 - band)), x $x1 (was $x0); menu bar bottom $mb"
drag_bg "$((x1 + 350))" "$((y1 - 16))" "$((x1 + 350))" "$((y1 - 16 + 200))" 300
wait "$bg"
sleep 0.4
read -r _ y2 _ _ < <(geom '^foot$')
(( y2 >= y1 + 195 && y2 <= y1 + 205 ))
check "P3 it can be grabbed again: a drag down by 200 moves it down" $? "y $y1 -> $y2"
pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
sleep 1

# ---- R: a resize from the bottom edge never moves the window ----
say "R foot with its titlebar under the menu bar, resized from its bottom edge"
p=$(client_run foot foot --window-size-pixels=700x400); pids+=("$p")
wait_mapped '^foot$' || { say "setup error: foot did not map"; exit 2; }
place '^foot$' 300 "$mb"
sleep 0.4
read -r rx0 ry0 _ rh0 < <(geom '^foot$')
click_at "$((rx0 + 350))" "$((ry0 + 200))" # focus (a click in the terminal)
# 3 px below the surface: Hyprland's border grab area (resize_on_border, extend_border_grab_area 8).
drag_bg "$((rx0 + 350))" "$((ry0 + rh0 + 3))" "$((rx0 + 350))" "$((ry0 + rh0 + 103))" 300
wait "$bg"
sleep 0.4
read -r _ ry1 _ rh1 < <(geom '^foot$')
(( rh1 >= rh0 + 50 ))
check "R0 the bottom edge was dragged (the window grew)" $? "height $rh0 -> $rh1"
(( ry1 == ry0 ))
check "R1 its top did not move (a resize from another edge is never held)" $? "top $ry0 -> $ry1, titlebar top $((ry1 - band)), menu bar bottom $mb"
pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
sleep 1

# ---- C: Chromium, client chrome (its own tab strip) ----
if command -v chromium >/dev/null; then
  say "C Chromium (client chrome: its own tab strip, Hyprland's move)"
  p=$(client_run chromium chromium --user-data-dir="$work/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic \
    --disable-background-networking --disable-component-update --disable-sync --proxy-server="$dead_proxy" \
    --ozone-platform=wayland --window-size=1100,700 about:blank); pids+=("$p")
  if wait_mapped '^chromium$' 80; then
    sleep 2
    place '^chromium$' 300 300
    read -r cx0 cy0 cw _ < <(geom '^chromium$')
    tags=$(client '^chromium$' '.tags | join(",")')
    say "  chromium at ($cx0,$cy0), width $cw, tags '$tags'"
    grab_x=$((cx0 + cw * 3 / 4)) grab_y=$((cy0 + 18)) # empty tab strip
    click_at "$grab_x" "$grab_y" # focus first: Chromium may take the first press on an unfocused window for itself
    # Hyprland's move (no tiling on this path): the pointer goes onto the menu bar, so the window's top ends under it
    # whatever Chromium's own drag threshold leaves as the grab offset.
    drag_bg "$grab_x" "$grab_y" "$grab_x" 2 1500
    sleep 1.6
    read -r _ cym _ _ < <(geom '^chromium$')
    wait "$bg"
    sleep 0.6
    read -r cx1 cy1 _ _ < <(geom '^chromium$')
    say "  C0 reported: while the button was held its top was at $cym (menu bar bottom $mb)"
    (( cym < mb ))
    check "C0 the drag did put its top under the menu bar (else C1 proves nothing)" $? "top $cym while held, menu bar bottom $mb"
    (( cy1 >= mb - 1 && cy1 <= mb + 1 ))
    check "C1 after the release its top is at the menu bar's bottom" $? "top $cy1 (held at $cym), menu bar bottom $mb; x $cx1 (was $cx0)"
    say "  plugin log: $(ctl rollinglog 2>/dev/null | grep -a "top clamp" | tail -n 1 | sed 's/.*\[grassfield\] //')"
    drag_bg "$((cx1 + cw * 3 / 4))" "$((cy1 + 18))" "$((cx1 + cw * 3 / 4))" "$((cy1 + 18 + 200))" 300
    wait "$bg"
    sleep 0.6
    read -r _ cy2 _ _ < <(geom '^chromium$')
    (( cy2 >= cy1 + 150 ))
    check "C2 it can be grabbed again by its tab strip: a drag down moves it down" $? "top $cy1 -> $cy2"
    grep -a "top clamp" "$log" >/dev/null 2>&1 || true
  else
    check "C chromium mapped" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
else
  say "C Chromium not installed: the client-chrome case is NOT VERIFIED here"
fi

say "top_clamp: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
