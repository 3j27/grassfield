#!/usr/bin/env bash
# Captures for the folder colours feature (docs/specs/files.md "Folder colours"): Files in the four views, Get Info,
# Customize Folder, the desktop and Settings > Appearance, with a global folder colour and per-folder looks. NOT a
# regression scenario (it is not under scenarios/, no baselines): it writes .dev/visual/folder-colours/<name>.<lang>.png
# to look at. Run it as a BARE command; VISUAL_LANG=en|fr (the lang is passed as the first argument too).
#
#   tests/visual/folder-colours.sh [en|fr]
#
# Every folder it customises lives under .dev/visual/ (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
OUT=$VS_STATE/folder-colours
mkdir -p "$OUT"
SB=$VS_STATE/folder-colours-sandbox
DESK=$VS_STATE/desktop

setattr() { # setattr FOLDER JSON  (an xattr on a folder inside .dev/visual only)
  case $(realpath -m -- "$1") in "$VS_STATE"/*) ;; *) echo "refusing $1" >&2; return 1 ;; esac
  setfattr -n user.grassfield.folder -v "$2" "$1"
}

fixtures() {
  rm -rf "$SB"
  mkdir -p "$SB"/{Documents,Pictures,Music,Projects,Travel,Archive,Plain}
  printf 'hello\n' > "$SB/readme.txt"
  printf 'a,b\n1,2\n' > "$SB/table.csv"
  touch -d "2026-10-01 12:00:00" "$SB"/* 2>/dev/null || true
  setattr "$SB/Music" '{"v":1,"color":"#e5484d","glyph":"🎵"}'
  setattr "$SB/Projects" '{"v":1,"color":"#3fae5a","glyph":"⭐"}'
  setattr "$SB/Travel" '{"v":1,"color":"#e25aa1","glyph":"✈️"}'
  setattr "$SB/Archive" '{"v":1,"color":"#8a8f98"}'
  setattr "$SB/Pictures" '{"v":1,"glyph":"📷"}'
  # Desktop sandbox of the shell: two customised folders.
  mkdir -p "$DESK/Work" "$DESK/Music"
  setattr "$DESK/Work" '{"v":1,"color":"#f5883b","glyph":"💼"}'
  setattr "$DESK/Projects" '{"v":1,"color":"#8e5bea"}'
}

set_global() { # set_global theme|accent|#rrggbb
  mkdir -p "$VS_DEV/config"
  printf '{"version":1,"icons":{"folderColor":"%s"}}\n' "$1" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
}

shot() { VS_NOPARK=${VS_NOPARK:-} vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }

key() { "$VS_ROOT/scripts/dev/keys.sh" "$@"; vs_sleep 0.8; }

vs_session
fixtures
vs_reset

# Settings: Appearance with the folder colour row (global: Theme).
set_global theme
vs_spawn "$VS_DEV/build/grassfield-settings"
vs_wait_clients 1
vs_sleep 2
shot fc-settings
vs_kill_clients

# Files in the four views, theme folder colour first.
vs_spawn "$VS_DEV/build/grassfield-files" "$SB"
vs_wait_clients 1
vs_sleep 3
key -M ctrl -k 1 -m ctrl
shot fc-files-icons-theme
set_global accent
shot fc-files-icons-accent
set_global "#3e7bfa"
shot fc-files-icons-blue
key -M ctrl -k 2 -m ctrl
shot fc-files-list
key -M ctrl -k 3 -m ctrl
shot fc-files-columns
key -M ctrl -k 4 -m ctrl
shot fc-files-gallery
key -M ctrl -k 1 -m ctrl
set_global accent
vs_kill_clients

# Desktop (the shell's sandbox desktop is $DESK).
vs_reset
shot fc-desktop
set_global theme
vs_ipc controlcenter reduceMotion true >/dev/null
shot fc-desktop-theme
echo "captures in $OUT"
