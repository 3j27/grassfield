#!/usr/bin/env bash
# Three Files defects found by the website captures of 2026-10-30, checked in the nested session the way a user meets them
# (VISUAL_LANG=fr for the French pass):
#   1. Columns view: the preview column of a selected picture shows the picture (it showed the type icon when the picture
#      was the first file of its column: PreviewPane asked for its preview only on a change of its row);
#   2. the Applications location keeps the global menus (File, Edit, View, Go) in the menu bar, as a folder does: Go >
#      Applications in an open window, and a window opened on Applications;
#   3. Open With > Other… preselects the picture's default application, Omarchy's imv (NoDisplay=true: the Apps grid and the
#      Applications location hide it, the Open With submenu lists it), and Open is enabled.
# Files runs on the nested session's private bus (vs_spawn), where grassfield-menu-bridge serves its menus; its picture
# associations are Omarchy's (/usr/share/omarchy/default/applications/mimeapps.list: image/png=imv.desktop), copied into its
# isolated config. Nothing is opened: GRASSFIELD_FILES_NO_LAUNCH, and the panel is closed with Escape.
# Checks: pixels of the fixture picture (an unusual flat colour) for 1, the shell's menu bar test hook (menubar bridgeState)
# for 2, the panel's accessibility tree (tests/visual/a11y-find.py) for 3.
# Captures: $VS_SHOTS/flow-files-fixes-*.<lang>.png.
# Run (bare command; starts a nested session when none is up): tests/visual/files-capture-fixes.sh
source "$(dirname "$0")/flow-lib.sh"
fl_start files-fixes

bin=$VS_DEV/build/grassfield-files
[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
work=$VS_STATE/files-fixes
case $work in "$VS_ROOT"/.dev/visual/files-fixes) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
rm -rf -- "$work"
mkdir -p "$work/Pictures"
colour='#c0208a'
# The first file of the column (the defect needed row 0), then a text file.
magick -size 640x480 "xc:$colour" "$work/Pictures/A photo.png"
printf 'notes\n' > "$work/Pictures/notes.txt"
# vs_spawn's isolated homes (.dev/isolated/visual, emptied by vs_session): Omarchy's picture associations.
omarchy_mimeapps=/usr/share/omarchy/default/applications/mimeapps.list
mkdir -p "$VS_DEV/isolated/visual/config"
if [[ -f $omarchy_mimeapps ]]; then
  cp "$omarchy_mimeapps" "$VS_DEV/isolated/visual/config/mimeapps.list"
else
  printf '[Default Applications]\nimage/png=imv.desktop\n' > "$VS_DEV/isolated/visual/config/mimeapps.list"
fi
grep -q '^image/png=imv.desktop' "$VS_DEV/isolated/visual/config/mimeapps.list" || fl_note "image/png is not imv's in Omarchy's mimeapps.list here"
[[ -f /usr/share/applications/imv.desktop ]] || fl_note "imv is not installed: item 3 checks another default"

class='^org\.grassfield\.Files$'
bridge() { fl_json menubar bridgeState "$VS_OUTPUT"; }
menus() { bridge | jq -c '.menus' 2>/dev/null; }
has_menus() { [[ $(bridge | jq '.menus | length' 2>/dev/null) -ge 4 ]]; }
menus_are() { [[ $(menus) == "$1" ]]; }
colour_px() { magick "$1" -alpha off -fuzz 6% -fill black +opaque "$colour" -fill white -opaque "$colour" -format '%[fx:int(mean*w*h+0.5)]' info:; }
files_pid() { fl_clients "$class" | head -n 1 | cut -f1; }
a11y() { # PID ROLE-REGEX NAME-REGEX [options]
  local pid=$1 role=$2 name=$3
  shift 3
  env DBUS_SESSION_BUS_ADDRESS="$(<"$VS_DEV/bus.address")" python3 -I "$VS_HERE/a11y-find.py" --pid "$pid" --role "$role" --name "$name" "$@"
}
title_center() { # TITLE -> "x y" of that bridge menu title in the bar
  bridge | jq -r --arg t "$1" '.bar[] | select(.kind == "bridge" and .title == $t) | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"' | head -n 1
}
row_rect() { # REGEX -> "x y w h" of the first open bridge menu row whose text matches
  bridge | jq -r --arg r "$1" '[.popup[] | select(.text | test($r))][0] // empty | "\(.x) \(.y) \(.w) \(.h)"'
}

# Open the app on the folder (the window opens on the output under the pointer).
vs_pointer abs 960 540 sleep 100 click >/dev/null
vs_spawn env GRASSFIELD_FILES_NO_LAUNCH=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$bin" "$work/Pictures"
fl_check_wait "Files opens the Pictures folder" 30 fl_title_has "$class" 'Pictures'
fl_check "Files has the keyboard" fl_focus_class "$class"
fl_check_wait "the menu bar shows the window's menus in a folder ($(menus))" 20 has_menus
folder_menus=$(menus)

# 1. Columns view, the first file selected: the preview column shows the picture.
fl_appkey logo 3
vs_sleep 1.5
before=$(fl_shot 1-columns)
fl_focus_class "$class" >/dev/null
fl_type A
vs_sleep 3
after=$(fl_shot 1-column-preview)
n_before=$(colour_px "$before")
n_after=$(colour_px "$after")
fl_check "the preview column shows the picture ($n_after px of its colour, $n_before before the selection; need 10000 more)" test "$((n_after - n_before))" -ge 10000

# 2. The Applications location keeps the menus: Go > Applications (Ctrl+Shift+A) in this window...
fl_focus_class "$class" >/dev/null
fl_appkey ctrl+shift a
fl_check_wait "Go > Applications: the window shows the Applications location" 15 fl_title_has "$class" '^Applications$'
vs_sleep 3
fl_check_wait "the menu bar keeps the same menus in Applications ($(menus); in a folder: $folder_menus)" 15 menus_are "$folder_menus"
fl_shot 2-applications-menubar >/dev/null
# ... and in a window opened on Applications (a second process; its menus once it has the keyboard).
vs_spawn env GRASSFIELD_FILES_NO_LAUNCH=1 "$bin" grassfield-apps:/
fl_check_wait "a second window opens on Applications" 30 bash -c "[[ \$(\"$VS_ROOT/scripts/nestctl\" clients -j | jq '[.[] | select(.mapped and .class == \"org.grassfield.Files\")] | length') -ge 2 ]]"
vs_sleep 4
fl_check_wait "the window opened on Applications shows the menus too ($(menus))" 15 menus_are "$folder_menus"
fl_shot 2b-applications-new-window >/dev/null
# Close it (the newest Files process only).
newest=$(fl_clients "$class" | cut -f1 | sort -n | tail -n 1)
first=$(fl_clients "$class" | cut -f1 | sort -n | head -n 1)
[[ $newest != "$first" && $newest =~ ^[0-9]+$ ]] && dev_may_signal "$newest" && kill "$newest" 2>/dev/null
vs_sleep 1

# 3. Back in the folder, the picture selected: File > Open With > Other… preselects imv; Open is enabled.
fl_focus_class "$class" >/dev/null
fl_appkey ctrl bracketleft
fl_check_wait "Back returns to Pictures" 10 fl_title_has "$class" 'Pictures'
vs_sleep 1
fl_focus_class "$class" >/dev/null
fl_type A
vs_sleep 1
file_title=$(bridge | jq -r '.bar[] | select(.kind == "bridge") | .title' | head -n 1)
xy=$(title_center "$file_title")
fl_check "the menu bar's first menu is there ($file_title)" test -n "$xy"
# shellcheck disable=SC2086
[[ -n $xy ]] && vs_pointer abs $xy sleep 200 click sleep 400 >/dev/null
read -r x y w h <<<"$(row_rect '^(Open With|Ouvrir avec)$')"
if [[ -n ${x:-} ]]; then
  vs_pointer abs $((x + w / 3)) $((y + h / 2)) sleep 600 >/dev/null
  read -r x y w h <<<"$(row_rect '^(Other…|Autre…)$')"
fi
fl_check "File > Open With > Other… is found in the menu" test -n "${x:-}"
[[ -n ${x:-} ]] && vs_pointer abs $((x + w / 3)) $((y + h / 2)) sleep 200 click >/dev/null
fl_check_wait "the Choose Application panel opens (a second Files window)" 15 bash -c "[[ \$(\"$VS_ROOT/scripts/nestctl\" clients -j | jq '[.[] | select(.mapped and .class == \"org.grassfield.Files\")] | length') -ge 2 ]]"
pid=$(files_pid)
vs_sleep 3
fl_check "the picture's default application, imv, is listed and selected" a11y "$pid" 'list item' '^imv$' --state selected --wait 10
fl_check "Open is enabled" a11y "$pid" '(push )?button' '^(Open|Ouvrir)$' --state sensitive --wait 5
fl_shot 3-other-panel >/dev/null
fl_key -k Escape
vs_sleep 1

if grep -E "TypeError|ReferenceError|Binding loop" "$VS_DEV/isolated/visual/"*.log >/dev/null 2>&1; then fl_note "see the isolated logs"; fi
fl_done
