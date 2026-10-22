#!/usr/bin/env bash
# Settings > Wallpaper > Online and the desktop menu's "About This Wallpaper" in the nested session (ADR-0016 step 2), against the
# loopback stand-in server (no real network). Set VISUAL_LANG=fr for the French captures.
#   0. Off by default: the pane shows the Online tile and the footnote; nothing is requested.
#   1. Choosing the tile opens the opt-in disclosure (hosts, once a day, IP address); Cancel leaves everything as it was.
#   2. "Use Picture of the Day" writes wallpaper.source=online and wallpaper.online.provider=commons, the picture appears and
#      the pane shows the attribution (Title, Author, Source, Licence, Last updated).
#   3. The desktop menu offers About This Wallpaper and opens the same attribution.
#   4. Nothing cached and no connection: the artwork, and the pane says "Waiting for a connection".
# Usage (bare command): tests/visual/wallpaper-online-ui.sh      Captures: $VS_SHOTS/wallpaper-online-ui-*.<lang>.png
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/online-lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

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
vs_spawn "$VS_DEV/build/grassfield-settings" --section=wallpaper
vs_wait_clients 1
vs_sleep 3
vs_capture wallpaper-online-ui-0-default
check "off by default: no request before the user chose anything (requests: $(online_requests))" test "$(online_requests)" = 0

# --- 1. the disclosure
tile_x=${WPO_TILE_X:-897}
tile_y=${WPO_TILE_Y:-688}
vs_pointer abs "$tile_x" "$tile_y" sleep 300 click >/dev/null
vs_sleep 2
vs_capture wallpaper-online-ui-1-disclosure
check "choosing the tile alone changes nothing (source=$(jq -r '.wallpaper.source // "unset"' "$cfg" 2>/dev/null || echo unset), requests $(online_requests))" bash -c "[[ \$(jq -r '.wallpaper.source // \"unset\"' '$cfg' 2>/dev/null || echo unset) != online ]] && [[ $(online_requests) == 0 ]]"

# --- 2. Use Picture of the Day
use_x=${WPO_USE_X:-1205}
use_y=${WPO_USE_Y:-787}
vs_pointer abs "$use_x" "$use_y" sleep 300 click >/dev/null
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
about_x=${WPO_ABOUT_X:-640}
about_y=${WPO_ABOUT_Y:-445}
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
