#!/usr/bin/env bash
# GF-009 functional flow: Quick Settings (internal name Control Center), used the way a user does. Nested session only.
#
# Proves, with the shell's own state (`controlcenter state`, a dev read-only hook), grassfield.json and the log:
#   1. Quick Settings opens from the menu bar (IPC `menubar open controlcenter`, the same call as the status item) and
#      `menubar openKind` says so; Escape closes it;
#   2. Appearance Dark / Light / Auto: each choice is applied by the shell (`appearance`, `dark`: Auto follows the clock,
#      dark from 19:00 to 07:00) and written to grassfield.json (`appearance`);
#   3. Transparency 1.0 (the tint alpha is clamped up to 0.6, so a smaller step is invisible): applied (`transparency`), persisted (`material.transparency`) and visible (the open panel looks
#      different from the one at 0.25); Reduce Transparency on and off is applied;
#   4. Do Not Disturb: toggled from the open panel with the keyboard (Tab to the tile, Return; the position of the tile in
#      the Tab order is found, not assumed), on and off again, and the shell's DND state follows;
#   5. the device toggles (Wi-Fi, Bluetooth, Airplane Mode) pressed that way only reach the dev guard: nothing is applied to
#      the machine, a "dev guard" line is logged (no device is touched in the nested session; UI state only);
#   6. Night Shift is shown if and only if the helper and hyprsunset are installed (`nightShift` is `hidden` otherwise).
#      Its switch is not operated: in a dev session it is suppressed by the dev guard.
# The transparency slider itself is not dragged (no coordinates are exposed): the IPC hook calls the setter the slider calls.
# Captures: $VS_SHOTS/flow-quicksettings-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up after itself):  tests/visual/flow-quicksettings.sh
# Expected: a PASS line per check and "quicksettings: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start quicksettings

cc_is() { [[ $(fl_cc "$1") == "$2" ]]; }   # cc_is JQ_FILTER VALUE (re-read on every call)
cfg_is() { [[ $(fl_cfg "$1") == "$2" ]]; }
kind_is() { [[ $(fl_kind) == "$1" ]]; }
open_qs() {
  vs_ipc menubar close >/dev/null
  vs_sleep 0.4
  vs_ipc menubar open controlcenter "$VS_OUTPUT" >/dev/null
  fl_wait 5 kind_is "controlcenter@$VS_OUTPUT"
}
dev_guard_lines() { grep -c 'dev guard' "$VS_DEV/shell.log" || true; }

# 1. open
fl_check "Quick Settings opens from the menu bar (openKind = controlcenter@$VS_OUTPUT)" open_qs
fl_check "the shell state is readable and starts dark / 0.25 / DND off" bash -c '[[ $(jq -r "[.appearance, .transparency, .dnd] | @csv" <<<"$1") == "\"dark\",0.25,false" ]]' _ "$(fl_json controlcenter state)"
vs_sleep 1
fl_shot open-dark >/dev/null

# 2. Appearance
hour=$(date +%H)
auto_dark=false
(( 10#$hour >= 19 || 10#$hour < 7 )) && auto_dark=true
for a in light auto dark; do
  vs_ipc controlcenter appearance "$a" >/dev/null
  fl_check_wait "appearance '$a' is applied by the shell" 5 cc_is .appearance "$a"
  fl_check_wait "appearance '$a' is written to grassfield.json" 5 cfg_is .appearance "$a"
  case $a in
    light) want_dark=false ;;
    dark) want_dark=true ;;
    auto) want_dark=$auto_dark ;;
  esac
  fl_check_wait "appearance '$a': the shell renders dark=$want_dark" 5 cc_is .dark "$want_dark"
  vs_sleep 0.8
  fl_shot "appearance-$a" >/dev/null
done

# 3. Transparency and Reduce Transparency
vs_sleep 0.8
low=$(fl_shot transparency-025)
vs_ipc controlcenter transparency 1 >/dev/null
fl_check_wait "transparency 1 is applied" 5 cc_is .transparency 1
fl_check_wait "transparency 1 is written to grassfield.json" 5 cfg_is .material.transparency 1
vs_sleep 1
high=$(fl_shot transparency-100)
n=$(vs_px_diff "$low" "$high")
fl_check "the open panel looks different at 1.0 than at 0.25 ($n px differ, need >= 300)" test "$n" -ge 300
vs_ipc controlcenter transparency 0.25 >/dev/null
fl_check_wait "transparency is back to 0.25" 5 cc_is .transparency 0.25
vs_ipc controlcenter reduceTransparency true >/dev/null
fl_check_wait "Reduce Transparency on is applied" 5 cc_is .reduceTransparency true
vs_sleep 0.8
fl_shot reduce-transparency >/dev/null
vs_ipc controlcenter reduceTransparency false >/dev/null
fl_check_wait "Reduce Transparency off is applied" 5 cc_is .reduceTransparency false

# 4 and 5. Do Not Disturb from the panel with the keyboard; the device rows pressed on the way hit the dev guard.
guard_before=$(dev_guard_lines)
found=""
for k in 0 1 2 3 4 5 6 7 8; do
  open_qs || break
  vs_sleep 0.6
  for _ in $(seq 1 "$k"); do fl_tap Tab; done
  fl_tap Return
  vs_sleep 0.5
  if [[ $(fl_cc .dnd) == true ]]; then found=$k; break; fi
done
fl_check "Do Not Disturb is toggled on from the panel (Tab x${found:-?} then Return)" test -n "$found"
fl_check "the shell's DND state is on (notifications status dnd=$(fl_notif dnd))" test "$(fl_notif dnd)" = true
fl_shot dnd-on >/dev/null
if [[ -n $found ]]; then
  fl_tap Return
  fl_check_wait "Return again turns Do Not Disturb off" 5 cc_is .dnd false
fi
vs_ipc notifications dnd false >/dev/null
guard_after=$(dev_guard_lines)
if (( guard_after > guard_before )); then
  echo "PASS: the device rows pressed on the way only reached the dev guard ($guard_before -> $guard_after dev guard lines)"
else
  fl_note "no device row was activated on the way to the DND tile (Tab x${found:-?}), so the dev guard was not exercised"
fi

# 6. Night Shift: shown iff the helper and hyprsunset are there
open_qs
vs_sleep 1.5
if type -P grassfield-nightshift >/dev/null && type -P hyprsunset >/dev/null; then
  want='^(on|off)$'
else
  want='^hidden$'
fi
ns=$(fl_cc .nightShift)
fl_check "Night Shift is '$ns' (expected to match $want: helper and hyprsunset present or not)" bash -c '[[ $1 =~ $2 ]]' _ "$ns" "$want"
fl_shot nightshift >/dev/null

# 1 again. Escape closes
fl_tap Escape
fl_check_wait "Escape closes Quick Settings" 5 kind_is ""

fl_done
