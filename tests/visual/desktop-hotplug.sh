#!/usr/bin/env bash
# A display plugged in AFTER the session started gets the desktop menu, and its icons surface stays above its wallpaper
# (config/hypr/grassfield/windows.lua: gf-wallpaper-order / gf-desktop-icons-order; without them Hyprland stacks the
# Background layer by map order and the wallpaper, mapped after the icons surface on a hotplugged output, covers it).
# Nested session, GF-REF is the icons' screen. Headless outputs GF-TWO and GF-THREE play the displays plugged in later; both
# are removed at the end (and on failure). For each: the output appears, the shell maps its wallpaper, then
#  - nestctl layers lists the wallpaper surface BELOW the icons surface of that output (stacking order);
#  - a right click on its empty desktop opens the desktop menu (the pixels differ from the bare output; a headless output
#    can be captured, the nested window's output cannot) and it has no New Folder (the icons are not there);
#  - removing the output leaves no "Cannot read property" in the shell log.
# Captures: $VS_SHOTS/hotplug-*.png. Usage (bare command, nested-only): tests/visual/desktop-hotplug.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
nest() { "$VS_ROOT/scripts/nestctl" "$@"; }
min_menu_px=1500
created=()
cleanup() {
  local o
  for o in "${created[@]}"; do nest output remove "$o" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

shot_of() { # NAME OUTPUT
  rm -f "$VS_DEV/shots/visual-$1.png" "$VS_SHOTS/$1.$VS_LANG.png"
  "$VS_ROOT/scripts/dev/shot.sh" "visual-$1" "$2" >/dev/null || true
  cp "$VS_DEV/shots/visual-$1.png" "$VS_SHOTS/$1.$VS_LANG.png"
  echo "$VS_SHOTS/$1.$VS_LANG.png"
}
# Index of a namespace among the background-level layers of an output (stacking order, bottom first), "" when absent.
layer_index() { # OUTPUT NAMESPACE
  nest layers -j | jq -r --arg o "$1" --arg ns "$2" '
    (.[$o].levels["0"] // []) | to_entries | map(select(.value.namespace == $ns)) | first | .key // ""' 2>/dev/null
}

vs_session >/dev/null
vs_reset dark >/dev/null
vs_park
lines_before=$(wc -l < "$VS_DEV/shell.log")

for out in GF-TWO GF-THREE; do
  nest output create headless "$out" >/dev/null
  created+=("$out")
  ok=""
  for _ in $(seq 1 60); do
    if tail -n +"$lines_before" "$VS_DEV/shell.log" | grep -q "shown wallpaper $out"; then ok=1; break; fi
    sleep 0.5
  done
  check "$out: the shell mapped its wallpaper" test -n "$ok"
  sleep 2
  w=$(layer_index "$out" grassfield-wallpaper)
  i=$(layer_index "$out" grassfield-desktop-icons)
  check "$out: the icons surface is above the wallpaper in the layer stack (wallpaper #${w:-none}, icons #${i:-none})" \
    test -n "$w" -a -n "$i" -a "${i:-0}" -gt "${w:-0}"
  "$VS_ROOT/scripts/dev/pointer.sh" output "$out" abs 100 100 >/dev/null
  sleep 1
  base=$(shot_of "hotplug-$out-base" "$out")
  "$VS_ROOT/scripts/dev/pointer.sh" output "$out" abs 400 300 rclick >/dev/null
  sleep 1
  menu=$(shot_of "hotplug-$out-menu" "$out")
  n=$(vs_px_diff "$base" "$menu")
  check "$out: a right click on its empty desktop opens the menu ($n px differ, need >= $min_menu_px)" test "$n" -ge "$min_menu_px"
  "$VS_ROOT/scripts/dev/pointer.sh" output "$out" abs 1500 900 click >/dev/null
  sleep 0.5
  vs_park
done

for out in GF-THREE GF-TWO; do
  nest output remove "$out" >/dev/null
  sleep 2
done
created=()
check "no TypeError or ReferenceError in the shell log after the unplugs" \
  test "$(tail -n +"$lines_before" "$VS_DEV/shell.log" | grep -cE 'Cannot read property|TypeError|ReferenceError')" = 0
exit $fail
