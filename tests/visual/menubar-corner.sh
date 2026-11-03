#!/usr/bin/env bash
# A window at the top-left right under the menu bar (tiled to top-left, and dragged up to the bar's edge), with the plugin loaded: the
# corner area zoomed, light and dark, "Tiled windows have margins" on and off. Looks for the menu bar glued to the titlebar's
# rounded corners (macOS: the window keeps its rounded corners, the wedges outside them show the bar or the wallpaper; tiled windows keep
# margins when the setting is on). Writes $VS_STATE/menubar-corner/mc-<case>.<lang>.png (full) and mc-<case>-zoom.png (the corner, x4).
# Usage (bare command): tests/visual/menubar-corner.sh ["light dark"] ["on off"] [place]     (place: top-left, left, fill, ...)
source "$(dirname "$0")/lib.sh"
APPEARANCES=${1:-"light dark"}
MARGINS=${2:-"on off"}
PLACE=${3:-top-left}
OUT=$VS_STATE/menubar-corner
mkdir -p "$OUT"

config() { # config APPEARANCE MARGINS
  mkdir -p "$VS_DEV/config"
  local m=true
  [[ $2 == off ]] && m=false
  printf '{"version":1,"appearance":"%s","lock":{"idleMinutes":0},"menubar":{"showBackground":%s},"windows":{"tilingMargins":%s}}\n' "$1" "${BAND:-true}" "$m" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 2
}
tile() { # tile PLACE: the plugin's tile verb on the foot window
  local addr
  addr=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.class == "foot")][0].address')
  "$VS_ROOT/scripts/nestctl" dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.tile then p.tile(\"$addr\", \"$1\") end end" >/dev/null 2>&1 || true
}

vs_session >/dev/null
vs_reset >/dev/null
vs_foot mc-foot 60x14 >/dev/null
vs_wait_clients 1 >/dev/null || true
vs_sleep 1.5
for appearance in $APPEARANCES; do
  for margins in $MARGINS; do
    config "$appearance" "$margins"
    vs_ipc controlcenter appearance "$appearance" >/dev/null
    tile "$PLACE"
    vs_sleep 1.5
    name=mc-$PLACE-$appearance-margins-$margins
    vs_capture "$name" >/dev/null
    cp "$VS_SHOTS/$name.$VS_LANG.png" "$OUT/"
    magick "$OUT/$name.$VS_LANG.png" -crop 260x90+0+0 +repage -filter point -scale 400% "$OUT/$name-zoom.png"
    echo "$OUT/$name-zoom.png"
  done
done
vs_kill_clients
