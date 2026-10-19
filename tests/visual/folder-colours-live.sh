#!/usr/bin/env bash
# A look set by another tool shows in an open Files window without a reload (docs/specs/files.md "Change detection"):
# Files shows a folder, setfattr gives one of its folders a colour and a symbol from outside, and the capture taken a
# moment later shows it (no Ctrl+R, no navigation). NOT a regression scenario: it writes
# .dev/visual/folder-colours-live/{before,after}.<lang>.png and prints the number of pixels that changed in the icon
# area (exit 1 when none did). Run it as a BARE command.
#
#   tests/visual/folder-colours-live.sh [en|fr]
#
# The folders live under .dev/visual/ (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
OUT=$VS_STATE/folder-colours-live
mkdir -p "$OUT"
SB=$VS_STATE/folder-colours-live-sandbox

rm -rf "$SB"
mkdir -p "$SB"/{Alpha,Beta,Gamma}

vs_session
vs_reset
printf '{"version":1,"appearance":"dark","icons":{"folderColor":"theme","mode":"default"}}\n' > "$VS_DEV/config/grassfield.json"
vs_sleep 1.5
vs_spawn "$VS_DEV/build/grassfield-files" "$SB"
vs_wait_clients 1
vs_sleep 3
"$VS_ROOT/scripts/dev/keys.sh" -M ctrl -k 1 -m ctrl
vs_sleep 0.8
vs_capture before >/dev/null
cp "$VS_SHOTS/before.$VS_LANG.png" "$OUT/before.$VS_LANG.png"
case $(realpath -m -- "$SB/Beta") in "$VS_STATE"/*) ;; *) echo "refusing $SB/Beta" >&2; exit 1 ;; esac
setfattr -n user.grassfield.folder -v '{"v":1,"color":"#e5484d","glyph":"★"}' "$SB/Beta"
vs_sleep 2
vs_capture after >/dev/null
cp "$VS_SHOTS/after.$VS_LANG.png" "$OUT/after.$VS_LANG.png"
vs_kill_clients
# Icon area of the grid (cell pitch 118, first icon centre 751,331, 64 px icons): pixels that differ.
changed=$(magick compare -metric AE -fuzz 8% "$OUT/before.$VS_LANG.png" "$OUT/after.$VS_LANG.png" null: 2>&1 || true)
echo "changed pixels: $changed"
[[ ${changed%%[. ]*} -gt 100 ]]
