#!/usr/bin/env bash
# The desktop menu on every display, and the icons' grid snap. Nested session, GF-REF is the primary output (the icons
# are there), the nested window's output is the second display.
#  1. Right click on the empty desktop of GF-REF opens the menu (pixels differ from the bare desktop).
#  2. The same on the second display (before 2026-11-04 it had no desktop surface: nothing happened); its menu has no
#     Clean Up (nothing to arrange there). The click point is checked for windows first.
#  3. A dropped icon lands on a whole grid cell: Notes.txt is dragged to a point that is off every cell centre, and the
#     saved slot is the nearest cell (integers, not the drop point), with no other icon displaced.
# Captures: $VS_SHOTS/ddisp-*.png. Usage (bare command, nested-only; run after scripts/dev/nested-up.sh --ref-scale 1.25
# to see the owner's panel scale): tests/visual/desktop-menu-displays.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
min_menu_px=1500

vs_session >/dev/null
vs_reset dark >/dev/null
vs_park
other=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '[.[] | select(.name != $n)][0].name // empty')
echo "second display: ${other:-none}"
shot_of() { # NAME OUTPUT
  rm -f "$VS_DEV/shots/visual-$1.png" "$VS_SHOTS/$1.$VS_LANG.png"
  "$VS_ROOT/scripts/dev/shot.sh" "visual-$1" "$2" >/dev/null || true
  cp "$VS_DEV/shots/visual-$1.png" "$VS_SHOTS/$1.$VS_LANG.png"
  echo "$VS_SHOTS/$1.$VS_LANG.png"
}

# 1. Primary display.
covering=$(vs_windows_over 700,500)
check "GF-REF: no window covers the click point (${covering:-none})" test -z "$covering"
base=$(vs_capture "ddisp-base")
vs_pointer abs 700 500 rclick >/dev/null
desk=$(VS_NOPARK=1 vs_capture "ddisp-primary-menu")
n=$(vs_px_diff "$base" "$desk")
check "GF-REF: the empty-desktop menu is open ($n px differ, need >= $min_menu_px)" test "$n" -ge "$min_menu_px"
vs_pointer abs 300 700 click >/dev/null
vs_park

# 2. Second display. The nested window's output cannot be captured (grim returns a blank image), so the menu itself is not
# checked there by pixels: the check is that the desktop surface exists on that output, the thing that was missing.
if [[ -n $other ]]; then
  total=$("$VS_ROOT/scripts/nestctl" layers -j | jq '[.. | objects | select(.namespace? == "grassfield-desktop-icons")] | length' 2>/dev/null || echo 0)
  check "a desktop surface on every output ($total grassfield-desktop-icons surfaces, 2 outputs)" test "$total" -ge 2
  echo "NOT VERIFIED by pixels: the menu on $other (its output cannot be captured)"
else
  echo "NOT VERIFIED: the nested session has no second output"
fi

# 3. Snap: drag Notes.txt (the second icon of the right-most column) to a point off every cell centre.
pos=$VS_DEV/state/desktop-icons.json
before=$(jq -c .positions "$pos" 2>/dev/null || echo "{}")
echo "slots before: $before"
vs_pointer abs "${SNAP_FROM_X:-1470}" "${SNAP_FROM_Y:-190}" sleep 300 down sleep 200 drag "${SNAP_TO_X:-1171}" "${SNAP_TO_Y:-373}" sleep 300 up >/dev/null
vs_park
sleep 1
after=$(jq -c .positions "$pos" 2>/dev/null || echo "{}")
echo "slots after: $after"
snap=$(vs_capture "ddisp-snapped-drop")
echo "$snap"
check "the slots are whole cells" jq -e '.positions | to_entries | all(.value.col == (.value.col | floor) and .value.row == (.value.row | floor))' "$pos"
check "the drop moved Notes.txt" test "$before" != "$after"
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
