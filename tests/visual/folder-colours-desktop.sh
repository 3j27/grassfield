#!/usr/bin/env bash
# The desktop follows folder looks live: a folder style appearing in the per-user store (folder-styles.json, created
# after the shell started, as Files does on its first write) and an attribute written by another process plus the
# store's serial moving. Writes .dev/visual/folder-colours/fc-desktop-live-{before,store,attr}.<lang>.png. Not a
# regression scenario. BARE command.
#
#   tests/visual/folder-colours-desktop.sh [en|fr]
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
OUT=$VS_STATE/folder-colours
mkdir -p "$OUT"
DESK=$VS_STATE/desktop
shot() { vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }

vs_session
vs_reset
mkdir -p "$DESK/Work" "$DESK/Music" "$DESK/Projects"
for d in Work Music Projects; do setfattr -x user.grassfield.folder "$DESK/$d" 2>/dev/null || true; done
rm -f "$VS_DEV/config/folder-styles.json"
printf '{"version":1,"icons":{"folderColor":"theme"}}\n' > "$VS_DEV/config/grassfield.json"
vs_sleep 2
shot fc-desktop-live-before

# 1) The store appears (atomic replace, as Files writes it): Music gets a colour and a symbol.
printf '{"version":1,"serial":1,"folders":{"%s":{"color":"#e25aa1","glyph":"🎵"}}}\n' "$DESK/Music" > "$VS_DEV/config/folder-styles.json.tmp"
mv "$VS_DEV/config/folder-styles.json.tmp" "$VS_DEV/config/folder-styles.json"
vs_sleep 3
shot fc-desktop-live-store

# 2) Another process writes an attribute (Work) and the store's serial moves (what Files does on every write).
setfattr -n user.grassfield.folder -v '{"v":1,"color":"#f5883b","glyph":"💼"}' "$DESK/Work"
printf '{"version":1,"serial":2,"folders":{"%s":{"color":"#e25aa1","glyph":"🎵"}}}\n' "$DESK/Music" > "$VS_DEV/config/folder-styles.json.tmp"
mv "$VS_DEV/config/folder-styles.json.tmp" "$VS_DEV/config/folder-styles.json"
vs_sleep 3
shot fc-desktop-live-attr
setfattr -x user.grassfield.folder "$DESK/Work"
