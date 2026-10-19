#!/usr/bin/env bash
# Captures of Files (list at 16 px rows, icon view, gallery) in the four icon appearance modes and both appearances, for the
# look of real icons and folders on their system plates (ADR-0014, docs/specs/ui.md "Icon appearance modes"). NOT a regression
# scenario: writes .dev/visual/icon-modes-files/imf-<view>-<appearance>-<mode>.<lang>.png. Run it as a BARE command.
#
#   tests/visual/icon-modes-files.sh [en|fr] [quick]      quick: dark appearance + default and tinted only
#
# The folder it shows lives under .dev/visual (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
QUICK=${2:-}
OUT=$VS_STATE/icon-modes-files
mkdir -p "$OUT"
SB=$VS_STATE/icon-modes-sandbox

setattr() {
  case $(realpath -m -- "$1") in "$VS_STATE"/*) ;; *) echo "refusing $1" >&2; return 1 ;; esac
  setfattr -n user.grassfield.folder -v "$2" "$1"
}

rm -rf "$SB"
mkdir -p "$SB/Documents" "$SB/Pictures" "$SB/Music" "$SB/Projects" "$SB/Work"
setattr "$SB/Projects" '{"v":1,"color":"#e5484d","glyph":"★"}'
setattr "$SB/Work" '{"v":1,"color":"#3e7bfa","glyph":"💼"}'
printf 'hello\n' > "$SB/readme.txt"
printf '# notes\n' > "$SB/notes.md"
printf 'a,b\n1,2\n' > "$SB/table.csv"
printf '#!/bin/sh\n' > "$SB/script.sh"
printf 'x\n' > "$SB/archive.zip"
printf '%%PDF-1.4\n' > "$SB/paper.pdf"
printf '{}\n' > "$SB/data.json"
printf 'int main(){}\n' > "$SB/main.cpp"

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
[[ $QUICK == quick ]] && { appearances=(dark); modes=(default tinted); }

vs_spawn "$VS_DEV/build/grassfield-files" "$SB"
vs_wait_clients 1
vs_sleep 3
for view in list icons gallery; do
  case $view in
    icons) k=1 ;;
    list) k=2 ;;
    gallery) k=4 ;;
  esac
  "$VS_ROOT/scripts/dev/keys.sh" -M ctrl -k "$k" -m ctrl
  vs_sleep 1
  for appearance in "${appearances[@]}"; do
    for mode in "${modes[@]}"; do
      config "$appearance" "$mode"
      vs_ipc controlcenter appearance "$appearance" >/dev/null
      shot "imf-$view-$appearance-$mode"
    done
  done
done
vs_kill_clients
echo "captures in $OUT"
