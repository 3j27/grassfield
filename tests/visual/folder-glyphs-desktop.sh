#!/usr/bin/env bash
# Captures for the look of the symbol drawn on a coloured folder ON THE DESKTOP (docs/specs/files.md "Folder colours", gate A2
# for the symbol): the twelve folders of folder-glyphs.sh as desktop icons over the artwork, a black and a white wallpaper,
# in the dark and light appearance and in the four icon modes, each with a plain symbol and without. NOT a regression
# scenario: it writes .dev/visual/folder-glyphs-desktop/fgd-<kind>-<appearance>-<mode>-<wallpaper>.<lang>.png, which
# tests/visual/folder_glyph_contrast.py DIR --desktop measures. Run it as a BARE command.
#
#   tests/visual/folder-glyphs-desktop.sh [en|fr] [quick]      quick: dark + default mode + artwork only
#
# Every folder it customises lives under .dev/visual/desktop (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
QUICK=${2:-}
OUT=$VS_STATE/folder-glyphs-desktop
mkdir -p "$OUT"
DESK=$VS_STATE/desktop

FOLDERS=(
  "01 Theme:"
  "02 Accent:accent"
  "03 Red:#e5484d"
  "04 Orange:#f5883b"
  "05 Yellow:#e6b422"
  "06 Green:#3fae5a"
  "07 Blue:#3e7bfa"
  "08 Purple:#8e5bea"
  "09 Gray:#8a8f98"
  "10 White:#ffffff"
  "11 Black:#000000"
  "12 Lemon:#ffd60a"
)

setattr() { # setattr FOLDER JSON  (an xattr on a folder inside .dev/visual only)
  case $(realpath -m -- "$1") in "$VS_STATE"/*) ;; *) echo "refusing $1" >&2; return 1 ;; esac
  setfattr -n user.grassfield.folder -v "$2" "$1"
}

fixtures() { # fixtures GLYPH
  local glyph=$1 spec name color json
  for spec in "${FOLDERS[@]}"; do
    name=${spec%%:*}
    color=${spec#*:}
    mkdir -p "$DESK/$name"
    json="{\"v\":1"
    [[ -n $color ]] && json+=",\"color\":\"$color\""
    [[ -n $glyph ]] && json+=",\"glyph\":\"$glyph\""
    json+="}"
    setattr "$DESK/$name" "$json"
  done
}

config() { # config APPEARANCE MODE
  mkdir -p "$VS_DEV/config"
  printf '{"version":1,"lock":{"idleMinutes":0},"appearance":"%s","icons":{"folderColor":"theme","mode":"%s"}}\n' "$1" "$2" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
}

shot() { vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }

vs_session
vs_reset
# Only the twelve folders on the desktop: the fixtures of vs_fixtures (Notes.txt, Report.md, Archive.zip, Projects) would move
# them in the grid, and folder_glyph_contrast.py --desktop finds each folder by its slot (sorted by name, 8 per column from the right).
rm -f "$DESK/Notes.txt" "$DESK/Report.md" "$DESK/Archive.zip"
rmdir "$DESK/Projects" 2>/dev/null || true
vs_sleep 2
magick -size 64x64 xc:black "$OUT/wall-black.png"
magick -size 64x64 xc:white "$OUT/wall-white.png"

appearances=(dark light)
modes=(default dark clear tinted)
walls=(artwork black white)
[[ $QUICK == quick ]] && { appearances=(dark); modes=(default); walls=(artwork); }

for kind in symbol nothing; do
  case $kind in
    symbol) glyph="★" ;;
    nothing) glyph="" ;;
  esac
  fixtures "$glyph"
  vs_sleep 3
  for appearance in "${appearances[@]}"; do
    vs_ipc controlcenter appearance "$appearance" >/dev/null
    for mode in "${modes[@]}"; do
      config "$appearance" "$mode"
      for wall in "${walls[@]}"; do
        case $wall in
          artwork) vs_wallpaper "" ;;
          *) vs_wallpaper "$OUT/wall-$wall.png" ;;
        esac
        vs_sleep 1
        shot "fgd-$kind-$appearance-$mode-$wall"
      done
    done
  done
done
vs_wallpaper "" || true
echo "captures in $OUT"
