#!/usr/bin/env bash
# Three Files defects found by the website captures of 2026-10-30, checked in the nested session the way a user meets them:
#   1. Columns view: the preview column of a selected picture shows the picture (it showed the type icon when the picture
#      was the first file of its column: PreviewPane asked for its preview only on a change of its row);
#   3. Open With > Other… preselects the picture's default application, Omarchy's imv (NoDisplay=true: the Apps grid and the
#      Applications location hide it, the Open With submenu lists it), and Open is enabled;
#   2. the Applications location keeps the global menus (File, Edit, View, Go) in the menu bar, as a folder does: Go >
#      Applications in an open window, and a window opened on Applications (the bridge reads a menu again when the busy app
#      did not answer its first read in time: grassfield-menu-bridge's log is checked for a menu given up).
# Files runs on the nested session's private bus (vs_spawn), where grassfield-menu-bridge serves its menus; its picture
# associations are Omarchy's (/usr/share/omarchy/default/applications/mimeapps.list: image/png=imv.desktop), copied into its
# isolated config. Nothing is opened: GRASSFIELD_FILES_NO_LAUNCH, and the panel is closed with Escape. Menus are opened
# through the bar (menubar bridgeState gives the titles and rows: found by their place and name, never a fixed point).
# Checks: pixels of the fixture picture (an unusual flat colour) for 1, the panel's accessibility tree for 3
# (tests/visual/a11y-lib.sh), the menu bar test hook for 2.
# Captures: $VS_SHOTS/flow-files-fixes-*.<lang>.png.
# Run (bare command; starts a nested session when none is up): tests/visual/files-capture-fixes.sh [en|fr]
export VISUAL_LANG=${1:-${VISUAL_LANG:-en}}
source "$(dirname "$0")/flow-lib.sh"
source "$(dirname "$0")/a11y-lib.sh"
fl_start files-fixes
trap 'a11y_stop; fl_cleanup' EXIT
a11y_start || { echo "FAIL: no accessibility bus on the nested private bus (see $VS_STATE/a11y-launcher.log)"; exit 1; }

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
bridge_log=$VS_DEV/menu-bridge.log
# A read the bridge gave up: a "GetLayout ... failed" line that no "reading its menu again" line follows (MenuClient::fail).
given_up_count() { echo $(( $(grep -c "GetLayout on .* failed" "$bridge_log" 2>/dev/null || true) - $(grep -c "reading its menu again" "$bridge_log" 2>/dev/null || true) )); }
given_up_before=$(given_up_count)

class='^org\.grassfield\.Files$'
bridge() { fl_json menubar bridgeState "$VS_OUTPUT"; }
menus() { bridge | jq -c '.menus' 2>/dev/null; }
has_menus() { [[ $(bridge | jq '.menus | length' 2>/dev/null) -ge 4 ]]; }
menus_are() { [[ $(menus) == "$1" ]]; }
colour_px() { magick "$1" -alpha off -fuzz 6% -fill black +opaque "$colour" -fill white -opaque "$colour" -format '%[fx:int(mean*w*h+0.5)]' info:; }
files_count() { "$VS_ROOT/scripts/nestctl" clients -j | jq '[.[] | select(.mapped and .class == "org.grassfield.Files")] | length'; }
more_files() { [[ $(files_count) -gt $1 ]]; }
# menu_open N: click the Nth (0-based) application menu title of the bar (File 0, Edit 1, View 2, Go 3).
menu_open() {
  local xy
  xy=$(bridge | jq -r --argjson n "$1" '[.bar[] | select(.kind == "bridge")][$n] // empty | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"')
  [[ -n $xy ]] || return 1
  # shellcheck disable=SC2086
  vs_pointer abs $xy sleep 200 click sleep 400 >/dev/null
}
# menu_row REGEX [hover]: click (or only point at, to open a submenu) the first open menu row whose text matches.
menu_row() {
  local x y w h
  read -r x y w h <<<"$(bridge | jq -r --arg r "$1" '[.popup[] | select(.text | test($r))][0] // empty | "\(.x) \(.y) \(.w) \(.h)"')"
  [[ -n ${x:-} ]] || return 1
  if [[ ${2:-} == hover ]]; then
    vs_pointer abs $((x + w / 3)) $((y + h / 2)) sleep 600 >/dev/null
  else
    vs_pointer abs $((x + w / 3)) $((y + h / 2)) sleep 200 click >/dev/null
  fi
}

# Open the app on the folder (the window opens on the output under the pointer).
vs_pointer abs 960 540 sleep 100 click >/dev/null
vs_spawn env GRASSFIELD_FILES_NO_LAUNCH=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$bin" "$work/Pictures"
fl_check_wait "Files opens the Pictures folder" 30 fl_title_has "$class" 'Pictures'
fl_check "Files has the keyboard" fl_focus_class "$class"
fl_check_wait "the menu bar shows the window's menus in a folder ($(menus))" 20 has_menus
folder_menus=$(menus)
pid=$(fl_clients "$class" | head -n 1 | cut -f1)

# 1. View > as Columns, the first file selected: the preview column shows the picture.
menu_open 2 && menu_row '^(as Columns|en colonnes)$'
vs_sleep 1.5
fl_check "View > as Columns shows the column view (its Columns pane)" a11y_find "$pid" 'panel' '^(Columns|Colonnes)$' --wait 5
fl_focus_class "$class" >/dev/null
before=$(fl_shot 1-columns)
fl_type A
vs_sleep 3
after=$(fl_shot 1-column-preview)
n_before=$(colour_px "$before")
n_after=$(colour_px "$after")
fl_check "the preview column shows the picture ($n_after px of its colour, $n_before before the selection; need 10000 more)" test "$((n_after - n_before))" -ge 10000

# 3. The picture selected: File > Open With > Other… preselects imv; Open is enabled.
windows=$(files_count)
menu_open 0 && menu_row '^(Open With|Ouvrir avec)$' hover && menu_row '^(Other…|Autre…)$'
fl_check_wait "File > Open With > Other… opens the Choose Application panel" 15 more_files "$windows"
vs_sleep 3
fl_check "the picture's default application, imv, is listed and selected" a11y_find "$pid" 'list item' '^imv$' --state selected --wait 15
fl_check "Open is enabled" a11y_find "$pid" '(push )?button' '^(Open|Ouvrir)$' --state sensitive --wait 5
fl_shot 3-other-panel >/dev/null
fl_key -k Escape
fl_check_wait "Escape closes the panel" 10 bash -c "[[ \$(\"$VS_ROOT/scripts/nestctl\" clients -j | jq '[.[] | select(.mapped and .class == \"org.grassfield.Files\")] | length') -le $windows ]]"

# 2. Go > Applications (Ctrl+Shift+A) in this window keeps the menus...
fl_focus_class "$class" >/dev/null
fl_appkey ctrl+shift a
fl_check_wait "Go > Applications: the window shows the Applications location" 15 fl_title_has "$class" 'Applications'
vs_sleep 3
fl_check_wait "the menu bar keeps the same menus in Applications ($(menus); in a folder: $folder_menus)" 20 menus_are "$folder_menus"
fl_shot 2-applications-menubar >/dev/null
# ... and so does a window opened on Applications (a second process; its menus once it has the keyboard).
windows=$(files_count)
vs_spawn env GRASSFIELD_FILES_NO_LAUNCH=1 "$bin" grassfield-apps:/
fl_check_wait "a second window opens on Applications" 30 more_files "$windows"
fl_check_wait "the window opened on Applications shows the menus too ($(menus))" 25 menus_are "$folder_menus"
fl_shot 2b-applications-new-window >/dev/null
given_up=$(( $(given_up_count) - given_up_before ))
fl_check "the bridge gave up no Files menu (retries logged: $(grep -c 'reading its menu again' "$bridge_log" 2>/dev/null || true))" test "$given_up" -le 0

fl_done
