#!/usr/bin/env bash
# GF-009 functional flow: the Settings app, used the way a user does. Nested session only.
#
# Proves, with the compositor's window list, the shared grassfield.json (the dev config directory of this tree: the app
# writes it, the shell watches it) and the shell's own state (`controlcenter state`):
#   1. Grassfield Settings opens on a pane (--section=appearance, what Search and the desktop menu pass);
#   2. a setting is changed in the app with the keyboard (Tab to the Appearance control, Left/Right: Light, Dark, Auto;
#      the Tab count is found, not assumed): each choice is written to grassfield.json (`appearance`) AND applied by the
#      running shell (`appearance`, `dark`: Auto follows the clock, dark from 19:00 to 07:00);
#   3. the app and the shell agree after the change (a capture of the desktop behind the window is light in Light).
# Captures: $VS_SHOTS/flow-settings-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up its window):  tests/visual/flow-settings.sh
# Expected: a PASS line per check and "settings: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start settings

cfg_is() { [[ $(fl_cfg .appearance) == "$1" ]]; }
cc_is() { [[ $(fl_cc "$1") == "$2" ]]; }
class='org\.grassfield\.Settings'
active_is_settings() { [[ $("$VS_ROOT/scripts/nestctl" activewindow -j 2>/dev/null | jq -r .class) =~ ^org\.grassfield\.Settings$ ]]; }

fl_check "the config starts dark (appearance=$(fl_cfg .appearance))" bash -c '[[ $1 == dark || $1 == null ]]' _ "$(fl_cfg .appearance)"

# 1. open on a pane
vs_spawn "$VS_DEV/build/grassfield-settings" --section=appearance
fl_check_wait "Grassfield Settings opens" 20 fl_has_window "$class"
vs_sleep 2
dark=$(fl_shot appearance-dark)
if ! active_is_settings; then
  # (the window may open without the keyboard: a click on its title bar, the usual way a user focuses it)
  read -r wx wy ww _ <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.class == "org.grassfield.Settings") | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -n 1)"
  vs_pointer abs $((wx + ww / 2)) $((wy + 10)) sleep 200 click >/dev/null
  vs_sleep 0.8
fi
fl_check "Settings has the keyboard focus" active_is_settings

# 2. change the setting with the keyboard
found=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  fl_tap Tab
  fl_tap Left
  if fl_wait 2 cfg_is light; then found=$i; break; fi
done
fl_check "Left on the Appearance control writes appearance=light to grassfield.json (Tab x${found:-?})" test -n "$found"
fl_check_wait "the shell applies it (appearance=light, dark=false)" 8 cc_is '[.appearance, .dark] | @csv' '"light",false'
vs_sleep 1.5
light=$(fl_shot appearance-light)
n=$(vs_px_diff "$dark" "$light")
fl_check "the window and the desktop look different in Light ($n px differ from Dark, need >= 20000)" test "$n" -ge 20000

fl_tap Right
fl_check_wait "Right: Dark is written (appearance=dark)" 5 cfg_is dark
fl_check_wait "the shell applies Dark (dark=true)" 8 cc_is .dark true
fl_tap Right
fl_check_wait "Right again: Auto is written (appearance=auto)" 5 cfg_is auto
hour=$(date +%H)
auto_dark=false
(( 10#$hour >= 19 || 10#$hour < 7 )) && auto_dark=true
fl_check_wait "the shell applies Auto (appearance=auto, dark=$auto_dark by the clock)" 8 cc_is '[.appearance, .dark] | @csv' "\"auto\",$auto_dark"
fl_shot appearance-auto >/dev/null

# Back to dark for whatever runs next, and close the window
fl_tap Left
fl_tap Left
vs_ipc controlcenter appearance dark >/dev/null
fl_check_wait "the config is dark again" 5 cfg_is dark
fl_close_windows "$class"
no_settings() { [[ -z $(fl_clients "$class") ]]; }
fl_check_wait "the Settings window is closed" 10 no_settings

fl_done
