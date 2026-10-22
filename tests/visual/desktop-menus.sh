#!/usr/bin/env bash
# The desktop's context menus (macOS model, shell/desktop/IconMenu.qml) on GF-REF, dark and light at the default
# transparency: the empty-desktop menu, its Clean Up By submenu and the menu of an icon. Captures for the visual check
# ($VS_SHOTS/dmenu-*.png) plus one measured check: the menu is a real blur, so the edge of the Projects folder behind
# the icon menu does not show through. The menu is an xdg popup of the icons layer, blurred only by the layer rule
# gf-desktop-menu-blur (config/hypr/grassfield/windows.lua); without it the edge stood out (luminance deviation 6.0
# in that patch, 0.3 to 0.4 with it).
# Usage (bare command): tests/visual/desktop-menus.sh
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

vs_session >/dev/null
for appearance in dark light; do
  vs_reset "$appearance" >/dev/null
  vs_park
  # Empty desktop, then Clean Up By ▸ (its row, for a menu opened at 700,500).
  vs_pointer abs 700 500 rclick >/dev/null
  VS_NOPARK=1 vs_capture "dmenu-desktop-$appearance"
  vs_pointer abs 780 659 >/dev/null
  VS_NOPARK=1 vs_capture "dmenu-desktop-sub-$appearance"
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
  # Notes.txt, second icon of the right-most column; its menu opens to the left over Projects.
  vs_pointer abs 1848 190 rclick >/dev/null
  shot=$(VS_NOPARK=1 vs_capture "dmenu-icon-$appearance")
  echo "$shot"
  sd=$(edge_sd "$shot")
  check "$appearance: the folder edge behind the icon menu is blurred (deviation $sd < 2)" awk -v v="$sd" 'BEGIN { exit !(v < 2) }'
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
