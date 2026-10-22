#!/usr/bin/env bash
# Search with the query "files" at material transparency 0.8 and 1.0 (the wallpaper shows through), in the four icon modes and
# both appearances: the selected row (accent fill) and a normal row, for the plate of the system plate against them
# (ADR-0014). NOT a regression scenario: writes .dev/visual/icon-modes-search-transparency/st-<appearance>-<transparency>-<mode>.<lang>.png.
# Run it as a BARE command.
#
#   tests/visual/icon-modes-search-transparency.sh [en|fr] ["dark light"] ["0.8 1.0"] ["default dark clear tinted"]
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
APPEARANCES=${2:-"dark light"}
TRANSPARENCIES=${3:-"0.8 1.0"}
MODES=${4:-"default dark clear tinted"}
OUT=$VS_STATE/icon-modes-search-transparency
mkdir -p "$OUT"

vs_session
vs_reset
for appearance in $APPEARANCES; do
  for tr in $TRANSPARENCIES; do
    for mode in $MODES; do
      printf '{"version":1,"appearance":"%s","lock":{"idleMinutes":0},"icons":{"folderColor":"theme","mode":"%s"}}\n' "$appearance" "$mode" > "$VS_DEV/config/grassfield.json.tmp"
      mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
      vs_sleep 1.5
      vs_ipc controlcenter appearance "$appearance" >/dev/null
      vs_ipc controlcenter transparency "$tr" >/dev/null
      vs_ipc search open files >/dev/null
      vs_sleep 1.5
      name=st-$appearance-$tr-$mode
      vs_capture "$name" >/dev/null
      cp "$VS_SHOTS/$name.$VS_LANG.png" "$OUT/$name.$VS_LANG.png"
      vs_ipc search close >/dev/null
      vs_sleep 0.5
    done
  done
done
vs_ipc controlcenter transparency 0.25 >/dev/null
echo "captures in $OUT"
