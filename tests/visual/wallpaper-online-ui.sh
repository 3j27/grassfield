#!/usr/bin/env bash
# Settings > Wallpaper > Online and the desktop menu's "About This Wallpaper" in the nested session (ADR-0016 step 2), against the
# loopback stand-in server (no real network). Set VISUAL_LANG=fr for the French captures.
#   0. Off by default: the pane shows the Online tile and the footnote; nothing is requested.
#   1. Choosing the tile opens the opt-in disclosure (hosts, once a day, IP address); Cancel leaves everything as it was.
#   2. "Use Picture of the Day" writes wallpaper.source=online and wallpaper.online.provider=commons, the picture appears and
#      the pane shows the attribution (Title, Author, Source, Licence, Last updated).
#   3. The desktop menu offers About This Wallpaper and opens the same attribution.
#   4. Nothing cached and no connection: the artwork, and the pane says "Waiting for a connection".
# The controls of Settings are found by their accessible role and name (tests/visual/a11y-find.py, AT-SPI on the nested
# private bus), never by a screen point: the fixed point of the Online tile landed on "Add Video…" once the Videos grid came in
# above it (1fc836b). The shell fetches with the dev helper .dev/build/grassfield-wallpaper (WallpaperConfig.toolPath), which
# is built here when it is missing or older than its sources (apps/wallpaper-tool/build-direct.sh).
# Usage (bare command): tests/visual/wallpaper-online-ui.sh      Captures: $VS_SHOTS/wallpaper-online-ui-*.<lang>.png
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/online-lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# The helper the shell fetches with: checked once when the shell starts (WallpaperState.toolMissing), so before vs_session.
tool=$VS_DEV/build/grassfield-wallpaper
if [[ ! -x $tool || -n $(find "$VS_ROOT/apps/wallpaper-tool" -newer "$tool" -type f -print -quit) ]]; then
  echo "wallpaper-online-ui: building $tool (apps/wallpaper-tool/build-direct.sh)"
  "$VS_ROOT/apps/wallpaper-tool/build-direct.sh" > "$VS_DEV/wallpaper-tool-build.log" 2>&1 \
    || { echo "FAIL: the wallpaper helper $tool could not be built (see $VS_DEV/wallpaper-tool-build.log)"; exit 1; }
fi
[[ -x $tool ]] || { echo "FAIL: the wallpaper helper $tool is missing (apps/wallpaper-tool/build-direct.sh)"; exit 1; }

# a11y PID ROLE NAME-REGEX [--press]: the showing control of Settings (process PID) with that role and name (one JSON line).
a11y() {
  local pid=$1 role=$2 name=$3
  shift 3
  env DBUS_SESSION_BUS_ADDRESS="$(<"$VS_DEV/bus.address")" python3 -I "$VS_HERE/a11y-find.py" --pid "$pid" --role "$role" --name "$name" "$@"
}
settings_pid() { "$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.class == "org.grassfield.Settings")][0].pid // empty'; }

online_start
vs_session "$VS_LANG"
vs_reset
cfg=$VS_DEV/config/grassfield.json
rm -rf "$VS_DEV/cache/wallpapers/online"
export GRASSFIELD_PICTURES_DIR=$VS_DEV/wallpapers-e2e
st() { jq -r "$1" "$online_status_file" 2>/dev/null || echo none; }
wait_ready() { # up to 90 s for the output to be ready with an online picture
  local i
  for i in $(seq 1 90); do
    [[ $(st '.outputs["GF-REF"].state') == ready && $(st '.outputs["GF-REF"].source') == online ]] && return 0
    sleep 1
  done
  return 1
}

# --- 0. off by default
# Its accessibility tree on the private bus (Qt enables it only with an AT-SPI client unless told to).
vs_spawn env QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$VS_DEV/build/grassfield-settings" --section=wallpaper
vs_wait_clients 1
vs_sleep 3
vs_capture wallpaper-online-ui-0-default
check "off by default: no request before the user chose anything (requests: $(online_requests))" test "$(online_requests)" = 0
pid=$(settings_pid)
[[ -n $pid ]] || { echo "FAIL: no Settings window"; exit 1; }

# --- 1. the disclosure: the Online grid's Wikimedia Commons tile (its accessible name is the provider's full name, in
# either language), chosen through its own action (WallpaperGrid's Accessible.onPressAction, what a click runs).
use_name='^(Use Picture of the Day|Utiliser l’image du jour)$'
if tile=$(a11y "$pid" "radio button" 'Wikimedia Commons' --press); then
  echo "wallpaper-online-ui: chose the tile $tile"
  check "the disclosure opens: its Use Picture of the Day button is shown" a11y "$pid" "(push )?button" "$use_name" --wait 5
else
  check "the Online grid's Wikimedia Commons tile is found (accessible radio button)" false
fi
vs_sleep 1
vs_capture wallpaper-online-ui-1-disclosure
check "choosing the tile alone changes nothing (source=$(jq -r '.wallpaper.source // "unset"' "$cfg" 2>/dev/null || echo unset), requests $(online_requests))" bash -c "[[ \$(jq -r '.wallpaper.source // \"unset\"' '$cfg' 2>/dev/null || echo unset) != online ]] && [[ $(online_requests) == 0 ]]"

# --- 2. Use Picture of the Day (the disclosure's button, found by its name)
check "Use Picture of the Day is pressed" a11y "$pid" "(push )?button" "$use_name" --press --wait 5
vs_sleep 2
check "the choice is written (source=$(jq -r '.wallpaper.source' "$cfg" 2>/dev/null) provider=$(jq -r '.wallpaper.online.provider' "$cfg" 2>/dev/null))" test "$(jq -r '[.wallpaper.source, .wallpaper.online.provider] | join(",")' "$cfg" 2>/dev/null)" = "online,commons"
wait_ready || { echo "FAIL: the online picture never became ready"; fail=1; }
vs_sleep 3
vs_capture wallpaper-online-ui-2-online
scroll_y=${WPO_SCROLL_Y:-600}
vs_pointer abs 1300 "$scroll_y" scroll 60 >/dev/null
vs_sleep 1
vs_capture wallpaper-online-ui-2b-attribution
vs_kill_clients

# --- 3. the desktop menu
vs_sleep 2
vs_pointer abs 900 300 sleep 200 click >/dev/null
vs_sleep 1
vs_pointer abs 600 400 sleep 200 rclick >/dev/null
vs_sleep 2
vs_capture wallpaper-online-ui-3-menu
about_x=${WPO_ABOUT_X:-680}
about_y=${WPO_ABOUT_Y:-500}
vs_pointer abs "$((about_x + 10))" "$((about_y - 5))" sleep 300 abs "$((about_x + 12))" "$about_y" sleep 400 click >/dev/null
vs_sleep 2
vs_capture wallpaper-online-ui-4-about
vs_ipc menubar close >/dev/null || true
check "no QML error in the shell log" test "$(grep -E 'ERROR|TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log" | grep -vc 'PointerTheme')" = 0

# --- 4. nothing cached, no connection
online_mode fail
rm -rf "$VS_DEV/cache/wallpapers/online" "$VS_DEV/state/wallpaper-online.json"
jq '.wallpaper = {source: "builtin"}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop" >/dev/null
for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
vs_spawn "$VS_DEV/build/grassfield-settings" --section=wallpaper
vs_wait_clients 1
vs_sleep 3
jq '.wallpaper = {source: "online", online: {provider: "commons"}}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
for i in $(seq 1 40); do [[ $(st '.outputs["GF-REF"].state') == waiting ]] && break; sleep 1; done
vs_sleep 2
check "nothing cached and the server failing: the state is waiting (state=$(st '.outputs["GF-REF"].state'))" test "$(st '.outputs["GF-REF"].state')" = waiting
vs_capture wallpaper-online-ui-5-waiting
vs_kill_clients
exit $fail
