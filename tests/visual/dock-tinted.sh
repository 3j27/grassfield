#!/usr/bin/env bash
# The Dock's icons in every icon mode, light and dark appearance, with the owner's settings (pink accent, magnification 1.35,
# size 39), pinned apps (no folder stack: `folders` is empty). Looks for an outer halo around a tile (docs/specs/ui.md "Icon shader").
# Writes $VS_SHOTS/dock-tinted-<appearance>-<mode>.<lang>.png. Usage (bare command): tests/visual/dock-tinted.sh ["light dark"] ["tinted default dark clear"]
source "$(dirname "$0")/lib.sh"
APPEARANCES=${1:-"light dark"}
MODES=${2:-"tinted default dark clear"}
[[ -n ${3:-} ]] && export QT_SCALE_FACTOR=$3  # a HiDPI window pixel ratio for the shell (the shell is restarted by vs_session)
OUT=$VS_STATE/dock-tinted${3:+-x$3}
mkdir -p "$OUT"

config() { # config APPEARANCE MODE
  mkdir -p "$VS_DEV/config"
  printf '{"version":1,"appearance":"%s","lock":{"idleMinutes":0},"icons":{"mode":"%s","tint":"accent","folderColor":"accent"},"accent":{"color":"pink"},"dock":{"magnificationEnabled":true,"magnification":1.35,"size":39,"pinned":["foot","org.grassfield.Files","org.grassfield.Settings","org.grassfield.Preview","chromium","org.grassfield.Store"],"folders":[]}}\n' "$1" "$2" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 2
}

vs_session >/dev/null
vs_reset >/dev/null
for appearance in $APPEARANCES; do
  for mode in $MODES; do
    config "$appearance" "$mode"
    vs_ipc controlcenter appearance "$appearance" >/dev/null
    vs_capture "dock-tinted-$appearance-$mode" >/dev/null
    cp "$VS_SHOTS/dock-tinted-$appearance-$mode.$VS_LANG.png" "$OUT/"
    echo "$OUT/dock-tinted-$appearance-$mode.$VS_LANG.png"
  done
done
