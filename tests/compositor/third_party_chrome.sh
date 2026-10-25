#!/usr/bin/env bash
# L1 nested scenario (GF-056; ADR-0015 amendment 2026-10-25): an app on the session's third-party list draws its own window
# controls and gets no second set; every other window keeps the plugin's titlebar. macOS: one set of traffic lights,
# top-left: close, minimize, zoom.
#
# Usage: tests/compositor/third_party_chrome.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin and its private bus (.dev/bus.address). Every client
# starts through scripts/dev/isolated.sh (isolated homes, the dev dconf profile of scripts/dev/devenv.sh) on the private
# bus and the nested socket, never the owner's bus or home; Chromium with a throwaway profile under .dev/. hyprctl only
# through scripts/nestctl (read-only, plus window moves); captures with grim.
#
# Per app on the list that is installed (Chromium's browser window: its GTK integration; Obsidian: Electron), one at a
# time at the same place:
#   T  SESSION  its class carries the Hyprland tag grassfield-client-chrome (rule gf-client-chrome-third-party)
#   S  PLUGIN   no plugin strip above it (the measurement of client_chrome.sh)
#   Z  SESSION  its own zoom button maximizes it (fullscreen=1, exempt from the maximize suppression), a second press
#               restores it
#   M  PLUGIN   its own minimize button puts it on special:minimized (xdg set_minimized, the client-chrome bridge P5)
#   V  visual   a capture of its top band, .dev/third-party-chrome/<app>-top.png: its own close, minimize, zoom. The
#               script cannot judge a picture: it prints "visual NOT verified" with the path; whoever runs it judges the
#               captures and records the verdict.
# Not on the list, the plugin's titlebar kept (not tagged, the strip above them): foot; a Chromium web app (--app: no
# frame of its own); Evince (GTK3) and Nautilus (GTK4/libadwaita), header-bar apps whose own controls do not all work
# under Hyprland 0.56.2 (Evince's zoom button does nothing, Nautilus greys its minimize button: ADR-0015 amendment
# 2026-10-25), so they keep the plugin's working set next to theirs (reported, a capture each).
# The layout the clients are given: org.gnome.desktop.wm.preferences button-layout read in a client's environment
# (GSettings through the dev profile) and through the settings portal on the private bus (what GTK4 and Chromium read),
# both 'close,minimize,maximize:' (ADR-0002, packaging/dconf/grassfield.d/20-window-buttons.conf).
# Exit: 0 PASS (every automatic check; the captures still need a look), 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${TPC_OUTPUT:-GF-REF}
want_layout="'close,minimize,maximize:'"

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "third_party_chrome: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "third_party_chrome: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "third_party_chrome: no private bus (.dev/bus.address; nested-up.sh starts it)" >&2; exit 2 ;;
esac

work=$dev/third-party-chrome
rm -rf "$work"
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
# A client on the nested socket and the private bus, isolated (scripts/dev/isolated.sh): <name> <command...>
client_run() {
  local name=$1; shift
  WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus GDK_BACKEND=wayland ELECTRON_OZONE_PLATFORM_HINT=wayland \
    setsid "$root/scripts/dev/isolated.sh" --name "tpc-$name" -- "$@" >>"$log" 2>&1 </dev/null &
  echo $!
}
# The same environment, in the foreground (a query): <name> <command...>
client_query() {
  local name=$1; shift
  WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus timeout 20 "$root/scripts/dev/isolated.sh" --name "tpc-$name" -- "$@" 2>>"$log"
}

read -r mon_x mon_y mon_w mon_h < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "third_party_chrome: output $out not found" >&2; exit 2; }
ctl -j plugin list | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null \
  || { echo "third_party_chrome: the plugin is not loaded" >&2; exit 2; }

pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
}
trap cleanup EXIT

fail=0 visual=()
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class | test(\$c)) | $2" | head -1; }
geom() {
  ctl clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class | test($c)) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen)"' | head -1
}
wait_mapped() { local i; for i in $(seq 1 ${2:-60}); do [[ -n $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
wait_gone() { local i; for i in $(seq 1 40); do [[ -z $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
place() { # <class regex> <x> <y> (output px)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$(client "$1" .address)' })" >>"$log" 2>&1
  sleep 0.8
}
# The plugin strip above a surface (as in client_chrome.sh): 1 when two rows of the strip have the strip's colour at five
# points across the window, 0 otherwise. <png> <x> <y> <w> (output px).
strip_above() {
  local i r hexes=()
  for r in 4 $((GF_TB_HEIGHT - 4)); do
    for i in 20 35 50 65 80; do
      hexes+=("$(magick "$1" -format "%[hex:p{$(($2 + $4 * i / 100)),$(($3 - r))}]" info: 2>/dev/null | cut -c1-6)")
    done
  done
  python3 -I - "$(jq -r '.titlebar.backgroundDark.value' "$root/ui/tokens/tokens.json")" \
    "$(jq -r '.titlebar.backgroundLight.value' "$root/ui/tokens/tokens.json")" "${hexes[@]}" <<'PY'
import sys
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) if len(h) >= 6 else None
tokens = [rgb(t) for t in sys.argv[1:3]]
points = [rgb(h) for h in sys.argv[3:]]
def near(a, b):
    return a is not None and b is not None and max(abs(x - y) for x, y in zip(a, b)) <= 8
print(1 if points and all(any(near(p, t) for t in tokens) for p in points) else 0)
PY
}
# One window at (160,140): its tag, the strip above it, a capture of its top band. <label> <class regex> <tagged 0|1>
judge() {
  local label=$1 cls=$2 tagged=$3 x y w h tags strip
  place "$cls" 160 140
  read -r x y w h _ < <(geom "$cls")
  tags=$(client "$cls" '.tags | join(",")')
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/$label.png" 2>>"$log"
  strip=$(strip_above "$work/$label.png" "$x" "$y" "$w")
  magick "$work/$label.png" -crop "${w}x$((GF_TB_HEIGHT + 70))+${x}+$((y - GF_TB_HEIGHT))" +repage "$work/$label-top.png" 2>>"$log"
  if ((tagged)); then
    [[ $tags == *grassfield-client-chrome* ]]
    check "$label: tagged (SESSION)" $? "class $(client "$cls" .class), tags '$tags'"
    [[ $strip == 0 ]]
    check "$label: no plugin strip (PLUGIN)" $? "strip above ${w}x${h} at ($x,$y): $strip"
    visual+=("$label: its own close, minimize and zoom, one set (left in macOS order when the app follows the GTK layout): $work/$label-top.png")
  else
    [[ $tags != *grassfield-client-chrome* ]]
    check "$label: not tagged" $? "class $(client "$cls" .class), tags '$tags'"
    [[ $strip == 1 ]]
    check "$label: the plugin strip" $? "strip above ${w}x${h} at ($x,$y): $strip"
    visual+=("$label: the plugin's traffic lights (and, for a header-bar app, its own buttons too): $work/$label-top.png")
  fi
}
# The app's own buttons work: <label> <class regex> <minimize dx> <zoom dx> <dy> (offsets from the window's top-left; a
# negative dx counts from its right edge).
own_buttons() {
  local label=$1 cls=$2 mdx=$3 zdx=$4 dy=$5 fs1 fs2 ws w0
  # An offset from the right edge is taken at the window's first width and kept from its left edge: Obsidian's starter
  # window is not resizable, its content (and its controls) stays at its size in the corner of a zoomed box.
  read -r _ _ w0 _ _ < <(geom "$cls")
  ((mdx < 0)) && mdx=$((w0 + mdx))
  ((zdx < 0)) && zdx=$((w0 + zdx))
  at() { # <dx> -> "x y" (output px), from the window's current left edge
    local x y
    read -r x y _ _ _ < <(geom "$cls")
    echo "$((x + $1)) $((y + dy))"
  }
  pointer abs $(at "$zdx") sleep 80 click sleep 1000
  read -r _ _ _ _ fs1 < <(geom "$cls")
  pointer abs $(at "$zdx") sleep 80 click sleep 1000
  read -r _ _ _ _ fs2 < <(geom "$cls")
  [[ $fs1 == 1 && $fs2 == 0 ]]
  check "$label: its own zoom button zooms and unzooms (SESSION)" $? "fullscreen $fs1 then $fs2"
  pointer abs $(at "$mdx") sleep 80 click sleep 1500
  ws=$(client "$cls" .workspace.name)
  [[ $ws == special:minimized ]]
  check "$label: its own minimize button minimizes (PLUGIN P5)" $? "workspace '$ws'"
}
stop_app() { # <pid> <class regex>
  pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null
  wait_gone "$2" || say "  ($2 still mapped after the stop)"
}

say "third_party_chrome: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}, bus $bus"
pointer abs $((mon_w - 40)) $((mon_h / 2)) sleep 50

say "layout the clients are given"
gs=$(client_query layout gsettings get org.gnome.desktop.wm.preferences button-layout)
[[ $gs == "$want_layout" ]]
check "GSettings in a client's environment (dev profile ${DCONF_PROFILE:-of devenv.sh})" $? "$gs"
portal=$(client_query layout gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Settings.Read org.gnome.desktop.wm.preferences button-layout 2>&1)
[[ $portal == *"$want_layout"* ]]
check "the settings portal on the private bus (GTK4, Chromium)" $? "$portal"

say "foot (no frame of its own): the plugin's titlebar"
p=$(client_run foot foot --window-size-pixels=640x300); pids+=("$p")
wait_mapped '^foot$' || { say "setup error: foot did not map"; exit 2; }
judge foot '^foot$' 0
stop_app "$p" '^foot$'

for gtk in "evince|Evince (GTK3 header bar)|^org\\.gnome\\.Evince$|evince" "nautilus|Nautilus (GTK4/libadwaita header bar)|^org\\.gnome\\.Nautilus$|nautilus --new-window"; do
  IFS='|' read -r label title cls cmd <<<"$gtk"
  command -v "${cmd%% *}" >/dev/null || continue
  say "$title: not on the list, the plugin's titlebar (its own controls do not all work under Hyprland 0.56.2)"
  # shellcheck disable=SC2086 # the command and its arguments
  p=$(client_run "$label" $cmd); pids+=("$p")
  if wait_mapped "$cls"; then
    sleep 1.5
    judge "$label" "$cls" 0
  else
    check "$label: mapped" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" "$cls"
done

if command -v chromium >/dev/null; then
  cargs=(--user-data-dir="$work/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic
    --disable-background-networking --disable-component-update --disable-sync --ozone-platform=wayland --window-size=900,520)
  say "Chromium browser (its own frame, through its GTK integration)"
  p=$(client_run chromium chromium "${cargs[@]}" about:blank); pids+=("$p")
  if wait_mapped '^chromium$' 80; then
    sleep 2
    judge chromium '^chromium$' 1
    own_buttons chromium '^chromium$' 50 83 21
  else
    check "chromium: mapped as chromium" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" '^chromium$'
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
  sleep 1
  say "Chromium web app (--app: no frame of its own)"
  printf '<title>gf web app</title><body>web app</body>\n' >"$work/app.html"
  p=$(client_run chromium chromium "${cargs[@]}" --app="file://$work/app.html"); pids+=("$p")
  if wait_mapped '^chrome-' 80; then
    sleep 2
    judge webapp '^chrome-' 0
  else
    check "web app: mapped as chrome-*" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" '^chrome-'
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
fi

if command -v obsidian >/dev/null; then
  say "Obsidian (Electron, its own frame)"
  p=$(client_run obsidian obsidian); pids+=("$p")
  if wait_mapped '^md\.obsidian\.Obsidian$' 120; then
    sleep 2
    judge obsidian '^md\.obsidian\.Obsidian$' 1
    # Obsidian draws its controls at the top right, in its own order (minimize, zoom, close): it ignores the GTK layout.
    own_buttons obsidian '^md\.obsidian\.Obsidian$' -110 -67 15
  else
    check "obsidian: mapped as md.obsidian.Obsidian" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" '^md\.obsidian\.Obsidian$'
fi

say "captures (visual NOT verified by this script: judge each one)"
for v in "${visual[@]}"; do say "  visual NOT verified: $v"; done
say "third_party_chrome: $([[ $fail == 0 ]] && echo PASS || echo FAIL) (automatic checks)"
exit "$fail"
