#!/usr/bin/env bash
# Settings > Energy on a computer without a battery, and Battery > Options… on a laptop (the owner's report of rc1-22 on a
# desktop PC: no way to set the power profile, no way to keep it from sleeping), captured in the nested session at the
# owner's scale, 1.25 (GRASSFIELD_REF_SCALE; a session already up keeps its own scale: the capture's size says which).
# No battery is faked for the Settings app only, never for the machine: its DBUS_SYSTEM_BUS_ADDRESS names a socket that does
# not exist, so UPower does not answer (Main.qml reads that as no battery and shows Energy in Battery's place), and a PATH
# stub of omarchy-powerprofiles-list lists power-profiles-daemon's three profiles (a desktop with the daemon). The laptop part
# reads the real UPower (read-only) and is skipped on a machine without a battery. A dev session changes no power profile
# (SystemService refuses every action) and never suspends; nothing here acts on the machine.
# Checks: the accessibility tree (tests/visual/a11y-lib.sh): the sidebar row, the pop-up, the switch, the Options… sheet.
# Captures: $VS_SHOTS/flow-energy-*.<lang>.png.
# Run (bare command; starts a nested session when none is up): tests/visual/energy-pane.sh [en|fr]
export VISUAL_LANG=${1:-${VISUAL_LANG:-en}}
export GRASSFIELD_REF_SCALE=${GRASSFIELD_REF_SCALE:-1.25}
source "$(dirname "$0")/flow-lib.sh"
source "$(dirname "$0")/a11y-lib.sh"
fl_start energy light
trap 'a11y_stop; fl_cleanup' EXIT
a11y_start || { echo "FAIL: no accessibility bus on the nested private bus (see $VS_STATE/a11y-launcher.log)"; exit 1; }

bin=$VS_DEV/build/grassfield-settings
[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/settings/build-direct.sh)"; exit 1; }
class='^org\.grassfield\.Settings$'
fl_note "output scale: $("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .scale')"

stub=$VS_STATE/energy-bin
case $stub in "$VS_ROOT"/.dev/visual/energy-bin) ;; *) echo "FAIL: unsafe stub path"; exit 1 ;; esac
mkdir -p "$stub"
printf '#!/bin/sh\nprintf "performance\\nbalanced\\npower-saver\\n"\n' > "$stub/omarchy-powerprofiles-list"
chmod 755 "$stub/omarchy-powerprofiles-list"
settings_pid() { fl_clients "$class" | head -n 1 | cut -f1; }
no_settings() { [[ -z $(fl_clients "$class") ]]; }

# 1. A computer without a battery: Energy in Battery's place.
vs_pointer abs 960 540 sleep 100 click >/dev/null
vs_spawn env DBUS_SYSTEM_BUS_ADDRESS="unix:path=$VS_STATE/no-system-bus" PATH="$stub:$PATH" QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$bin" --section=battery
fl_check_wait "Settings opens" 30 fl_has_window "$class"
pid=$(settings_pid)
fl_check "the sidebar lists Energy" a11y_find "$pid" 'list item' '^Energy$' --wait 15
no_battery_row() { ! a11y_find "$pid" 'list item' '^Battery$' --wait 2 >/dev/null; }
fl_check "the sidebar has no Battery" no_battery_row
fl_check "Battery asked for: the Energy pane, with Energy Mode" a11y_find "$pid" 'combo box' '^Energy Mode$' --state sensitive --wait 10
fl_check "Prevent automatic sleeping when the display is off, on by default" a11y_find "$pid" 'check box' '^Prevent automatic sleeping when the display is off$' --state checked --wait 5
not_turned_off() { [[ $(fl_cfg '.energy.preventSleep') != false ]]; }
fl_check "grassfield.json does not turn it off (the default applies)" not_turned_off
vs_sleep 1.5
fl_shot energy-light >/dev/null
fl_close_windows "$class"
fl_check_wait "the Settings window is closed" 10 no_settings

# 2. A laptop: Battery > Options… (the real battery, read-only).
if compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then
  vs_spawn env QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$bin" --section=battery
  fl_check_wait "Settings opens" 30 fl_has_window "$class"
  pid=$(settings_pid)
  fl_check "the sidebar lists Battery" a11y_find "$pid" 'list item' '^Battery$' --wait 15
  fl_check "Options… opens the sheet" a11y_find "$pid" '(push )?button' '^Battery options$' --press --wait 10
  fl_check "the sheet: Prevent automatic sleeping on power adapter when the display is off" a11y_find "$pid" 'check box' '^Prevent automatic sleeping on power adapter when the display is off$' --state checked --wait 5
  vs_sleep 1.5
  fl_shot battery-options-light >/dev/null
  fl_close_windows "$class"
  fl_check_wait "the Settings window is closed" 10 no_settings
else
  fl_note "SKIP: this machine has no battery; Battery > Options… not captured"
fi
fl_done
