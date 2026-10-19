#!/usr/bin/env bash
# Captures for the look of the symbol drawn on a coloured folder (docs/specs/files.md "Folder colours", gate A2 for the
# symbol): twelve folders (theme, accent, the seven tag colours, white, black, yellow as typed hex colours) in the Files
# icon view, each with a plain symbol, then the same with an emoji, in light and dark appearance and in the four icon
# modes. NOT a regression scenario (no baselines): it writes .dev/visual/folder-glyphs/<name>.<lang>.png, and
# tests/visual/folder_glyph_contrast.py measures them. Run it as a BARE command.
#
#   tests/visual/folder-glyphs.sh [en|fr] [quick]      quick: dark + default mode only
#
# Every folder it customises lives under .dev/visual/ (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
QUICK=${2:-}
OUT=$VS_STATE/folder-glyphs
mkdir -p "$OUT"
SB=$VS_STATE/folder-glyphs-sandbox

# name:colour
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
  rm -rf "$SB"
  mkdir -p "$SB"
  for spec in "${FOLDERS[@]}"; do
    name=${spec%%:*}
    color=${spec#*:}
    mkdir -p "$SB/$name"
    json="{\"v\":1"
    [[ -n $color ]] && json+=",\"color\":\"$color\""
    [[ -n $glyph ]] && json+=",\"glyph\":\"$glyph\""
    json+="}"
    setattr "$SB/$name" "$json"
  done
}

config() { # config APPEARANCE MODE
  mkdir -p "$VS_DEV/config"
  printf '{"version":1,"appearance":"%s","icons":{"folderColor":"theme","mode":"%s"}}\n' "$1" "$2" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
}

shot() { vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }

vs_session
vs_reset

appearances=(dark light)
modes=(default dark clear tinted)
[[ $QUICK == quick ]] && { appearances=(dark); modes=(default); }

for kind in symbol emoji nothing; do
  case $kind in
    symbol) glyph="★" ;;
    emoji) glyph="🎵" ;;
    nothing) glyph="" ;;
  esac
  fixtures "$glyph"
  vs_spawn "$VS_DEV/build/grassfield-files" "$SB"
  vs_wait_clients 1
  vs_sleep 3
  "$VS_ROOT/scripts/dev/keys.sh" -M ctrl -k 1 -m ctrl
  vs_sleep 0.8
  for appearance in "${appearances[@]}"; do
    for mode in "${modes[@]}"; do
      [[ $kind == emoji && $mode != default ]] && continue
      config "$appearance" "$mode"
      shot "fg-$kind-$appearance-$mode"
    done
  done
  vs_kill_clients
done
echo "captures in $OUT"
