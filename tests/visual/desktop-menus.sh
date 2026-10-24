#!/usr/bin/env bash
# The desktop's context menus (macOS model, shell/desktop/IconMenu.qml) on GF-REF, dark and light at the default
# transparency: the empty-desktop menu, its Clean Up By submenu and the menu of an icon. Captures for the visual check
# ($VS_SHOTS/dmenu-*.png) plus measured checks: the menu is a real blur, so the edge of the Projects folder behind
# the icon menu does not show through. The menu is an xdg popup of the icons layer, blurred only by the layer rule
# gf-desktop-menu-blur (config/hypr/grassfield/windows.lua); without it the edge stood out (luminance deviation 6.0
# in that patch, 0.3 to 0.4 with it).
# GF-058: the captures must show the named menus. A window over a click point takes the click (a foot window covered the
# empty-desktop click while the test still passed), so the click points are checked for windows first; every menu is
# asserted open by pixels (it differs from the same desktop without it) before its capture, and closed again after the
# click away. The desktop widgets' clocks follow GRASSFIELD_FIXED_TIME, so the bare desktop is the same in every run.
# Usage (bare command, nested-only; starts a nested session when none is up): tests/visual/desktop-menus.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
# Luminance deviation (0-255) of a strip of the icon menu's right margin (no text) across the folder's top edge.
edge_sd() {
  magick "$1" -crop 8x60+1837+255 +repage -colorspace Gray -format '%[fx:int(standard_deviation*2550)/10]' info:
}

click_points=(700,500 780,659 1848,190 300,700)
min_menu_px=1500 # a menu is some 250x300 px of glass and text: far above the cursor (about 600 px) and antialiasing

vs_session >/dev/null
for appearance in dark light; do
  vs_reset "$appearance" >/dev/null
  vs_park
  covering=$(vs_windows_over "${click_points[@]}")
  check "$appearance: no window covers a click point (${covering:-none})" test -z "$covering"
  vs_ipc notifications clearAll >/dev/null || true
  base=$(vs_capture "dmenu-base-$appearance")
  # Empty desktop, then Clean Up By ▸ (its row, for a menu opened at 700,500).
  vs_pointer abs 700 500 rclick >/dev/null
  desk=$(VS_NOPARK=1 vs_capture "dmenu-desktop-$appearance")
  n=$(vs_px_diff "$base" "$desk")
  check "$appearance: the empty-desktop menu is open ($n px differ from the bare desktop, need >= $min_menu_px)" test "$n" -ge "$min_menu_px"
  vs_pointer abs 780 659 >/dev/null
  sub=$(VS_NOPARK=1 vs_capture "dmenu-desktop-sub-$appearance")
  n=$(vs_px_diff "$desk" "$sub")
  check "$appearance: the Clean Up By submenu is open ($n px differ from the menu alone, need >= 500)" test "$n" -ge 500
  vs_pointer abs 300 700 click >/dev/null
  vs_park
  closed=$(VS_NOPARK=1 vs_capture "dmenu-closed-$appearance")
  n=$(vs_px_diff "$base" "$closed")
  check "$appearance: the click away closed the menu ($n px differ from the bare desktop, need < 300)" test "$n" -lt 300
  # Notes.txt, second icon of the right-most column; its menu opens to the left over Projects.
  vs_pointer abs 1848 190 rclick >/dev/null
  shot=$(VS_NOPARK=1 vs_capture "dmenu-icon-$appearance")
  echo "$shot"
  n=$(vs_px_diff "$base" "$shot")
  check "$appearance: the icon menu is open ($n px differ from the bare desktop, need >= $min_menu_px)" test "$n" -ge "$min_menu_px"
  sd=$(edge_sd "$shot")
  check "$appearance: the folder edge behind the icon menu is blurred (deviation $sd < 2)" awk -v v="$sd" 'BEGIN { exit !(v < 2) }'
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
