#!/usr/bin/env bash
# Preview with ONE large PNG named like a grassfield-capture screenshot, in the light appearance: the title must start after the
# traffic lights and the image must be drawn (captures at 1 s, 3 s and 8 s after the window maps, to tell loading from failing).
# Standalone (not part of `just visual`). Run as a BARE command: tests/visual/preview-title.sh
# Shots: .dev/visual/preview-title/pt-*.en.png.
source "$(dirname "$0")/lib.sh"
vs_session

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

img=$VS_DEV/pt-img
mkdir -p "$img"
f="$img/Screenshot 2026-11-02 at 17.45.34.png"
if [[ ! -f $f ]]; then
  magick -size 3840x2160 gradient:'#f2c94c'-'#2f5fd0' -gravity center -pointsize 400 -fill white -annotate 0 "PNG" "$f"
fi
OUT=$VS_STATE/preview-title
mkdir -p "$OUT"

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" "$f"
vs_wait_clients 1
for t in 1 3 8; do
  vs_sleep "$t"
  vs_capture "pt-after-$t" >/dev/null
  cp "$VS_SHOTS/pt-after-$t.$VS_LANG.png" "$OUT/"
  echo "$OUT/pt-after-$t.$VS_LANG.png"
done
vs_kill_clients
