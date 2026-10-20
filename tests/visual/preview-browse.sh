#!/usr/bin/env bash
# Preview browsing (Track B2): open one image of a folder of 5 generated images, press Right 3 times, check the window
# title, capture; rotate and zoom; the sidebar; light appearance; a Glance with arrows. Standalone (not part of
# `just visual`: no baselines). Run as a BARE command: tests/visual/preview-browse.sh
# Shots: .dev/visual/shots/pv-*.en.png. Exit 1 when a title check fails.
source "$(dirname "$0")/lib.sh"
vs_session

# Same as vs_spawn, but the app's output is kept in .dev/preview.log (QML warnings are the first thing to read).
vs_spawn() {
  local sock bus=""
  sock=$(vs_nested_wayland)
  [[ -f $VS_DEV/bus.address ]] && bus=$(<"$VS_DEV/bus.address")
  "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
    env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="${bus:-}" LC_ALL=en_US.UTF-8 \
    QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$VS_ROOT/ui:$VS_DEV/build/qml" \
    GRASSFIELD_TRANSLATIONS_DIR="$VS_DEV/translations" GRASSFIELD_LANG="$(<"$VS_STATE/session.lang")" \
    HYPRLAND_INSTANCE_SIGNATURE="$(<"$VS_DEV/nested.instance")" "$@" >>"$VS_DEV/preview.log" 2>&1 </dev/null &
  vs_track "$!"
}

img=$VS_DEV/b2-img
mkdir -p "$img"
if [[ ! -f $img/img5.png ]]; then
  for i in 1 2 3 4 5; do
    magick -size 1200x800 gradient:'#d9453d'-'#2f5fd0' -gravity center -pointsize 220 -fill white -annotate 0 "$i" "$img/img$i.png"
  done
fi

title_of() { "$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.class == "org.grassfield.Preview")][0].title // "none"'; }
check_title() {
  local got
  got=$(title_of)
  if [[ $got != "$1" ]]; then echo "FAIL: title '$got', expected '$1'" >&2; fail=1; else echo "PASS: title $got"; fi
}
key() { "$VS_ROOT/scripts/dev/keys.sh" "$@"; vs_sleep 1.2; }
fail=0

vs_reset dark
vs_spawn "$VS_DEV/build/grassfield-preview" "$img/img2.png"
vs_wait_clients 1
vs_sleep 2
check_title img2.png
"$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | "client: \(.class) | \(.title) | pid \(.pid) | \(.size)"'
vs_capture pv-open-dark
key -k Right
key -k Right
key -k Right
check_title img5.png
vs_capture pv-right3-dark
key -k Right
check_title img5.png   # no wrap at the last image
key -M ctrl -k r -m ctrl
key -k plus
vs_capture pv-rotate-zoom-dark
key -M ctrl -M alt -k 2 -m alt -m ctrl
vs_capture pv-nosidebar-dark
key -M ctrl -k i -m ctrl
vs_capture pv-info-dark
key -k Left
check_title img4.png

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" "$img/img2.png"
vs_wait_clients 1
vs_sleep 2
vs_capture pv-open-light
key -M ctrl -M alt -k 2 -m alt -m ctrl
vs_capture pv-sidebar-light

vs_reset dark
vs_spawn "$VS_DEV/build/grassfield-preview" --glance "$img/img1.png" "$img/img2.png" "$img/img3.png"
vs_wait_clients 1
vs_sleep 2
vs_capture pv-glance-dark
key -k Right
vs_capture pv-glance-next-dark
vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" --glance "$img/img1.png" "$img/img2.png" "$img/img3.png"
vs_wait_clients 1
vs_sleep 2
vs_capture pv-glance-light
exit "$fail"
