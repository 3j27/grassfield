#!/usr/bin/env bash
# Captures of the Customize Folder flow (context menu, the window, Get Info) for docs/specs/files.md. Not a regression
# scenario: it writes .dev/visual/folder-colours/<name>.<lang>.png. BARE command, like tests/visual/folder-colours.sh.
#
#   tests/visual/folder-colours-ui.sh [en|fr] [stage]    stage: menu | window | keys | info | all (default all)
#
# Folders it touches live under .dev/visual/ only.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
STAGE=${2:-all}
OUT=$VS_STATE/folder-colours
mkdir -p "$OUT"
SB=$VS_STATE/folder-colours-sandbox

shot() { vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }
key() { "$VS_ROOT/scripts/dev/keys.sh" "$@"; vs_sleep 0.8; }
click() { vs_pointer abs "$1" "$2" sleep 300 click >/dev/null; vs_sleep 0.8; }
rclick() { vs_pointer abs "$1" "$2" sleep 300 rclick >/dev/null; vs_sleep 0.8; }

vs_session
vs_reset
rm -rf "$SB"
mkdir -p "$SB"/{Documents,Pictures,Music,Projects,Travel,Archive,Plain}
printf 'hello\n' > "$SB/readme.txt"
mkdir -p "$VS_DEV/config"
printf '{"version":1,"icons":{"folderColor":"theme"}}\n' > "$VS_DEV/config/grassfield.json"
vs_sleep 1.5
vs_spawn "$VS_DEV/build/grassfield-files" "$SB"
vs_wait_clients 1
vs_sleep 3
key -M ctrl -k 1 -m ctrl

# Icon view cells (1920x1080): row 1 at y 335; Archive x 751, Documents 869, Music 987, Pictures 1105, Plain 1223.
rclick 1223 335
VS_NOPARK=1 shot fc-menu
[[ $STAGE == menu ]] && exit 0
click 1040 494
vs_wait_clients 2
vs_sleep 2
VS_NOPARK=1 shot fc-customize
[[ $STAGE == window ]] && exit 0
if [[ $STAGE == keys ]]; then
  # Keyboard only: Tab walks swatches, hex field, symbol grid (focus ring on the first symbol), symbol field, Reset, Cancel, Done.
  key -k Tab
  key -k Tab
  key -k Tab
  VS_NOPARK=1 shot fc-keys-grid
  key -k Tab
  key 'Holiday photos'
  VS_NOPARK=1 shot fc-keys-field
  key -k Tab
  key -k Tab
  key -k Tab
  VS_NOPARK=1 shot fc-keys-done
  key -k Escape
  vs_sleep 1
  exit 0
fi
# Window at x 740-1180, y 261-761 on GF-REF: red swatch, the music note, Done.
click 930 430
click 946 529
VS_NOPARK=1 shot fc-customize-edit
click 1131 714
vs_sleep 1.5
shot fc-files-customized
[[ $STAGE == customize ]] && exit 0
key -M ctrl -k i -m ctrl
vs_wait_clients 2
vs_sleep 2
VS_NOPARK=1 shot fc-info
echo "done"
