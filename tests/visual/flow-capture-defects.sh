#!/usr/bin/env bash
# The capture defects of 2026-10-29, seen in a FRENCH nested session (fix/capture-defects-shell): one pass that shows each fix.
# Nested session only (fixtures). The session language is French unless VISUAL_LANG says otherwise.
#
#   1  widget gallery: French words, a French date, and the panel above the Dock (capture flow-capture-defects-gallery)
#   2  app menu shortcuts: unit-tested headless (tests/shell/menu_shortcut_fr); here the Window menu capture
#   3  input source: a virtual keyboard's layout "error" never shows (osd layout hook and a wtype key press)
#   4  brightness OSD: the machine's backlight does not draw it in a dev session (osd state)
#   6  switcher: Files, Settings, Preview and Activity Monitor are four apps; the list as the shell reports it
#   7  Glance: no Dock tile, the menu bar keeps naming the app that opened it (captures)
#   8  Dock stack Grid: long names wrap at words and truncate in the middle (capture)
#   9  menu check rows: the Window menu and a Dock menu with a checked window (captures)
#  10  input source name in French (osd layout hook with a real catalog: "Anglais (US)")
# Captures: $VS_SHOTS/flow-capture-defects-*.fr.png. Run as a BARE command:  tests/visual/flow-capture-defects.sh
export VISUAL_LANG=${VISUAL_LANG:-fr}
source "$(dirname "$0")/flow-lib.sh"
fl_start capture-defects

b=$VS_DEV/build
img=$VS_STATE/capture-defects-images
mkdir -p "$img"
magick -size 1200x800 gradient:'#d9453d'-'#2f5fd0' -gravity northwest -pointsize 220 -fill white -annotate +60+40 "1" "$img/img1.png"
magick -size 1200x800 gradient:'#2fa06d'-'#2f5fd0' -gravity northwest -pointsize 220 -fill white -annotate +60+40 "2" "$img/img2.png"

# ---- 1. the widget gallery, in French ---------------------------------------------------------------------------
vs_ipc dock autohide false >/dev/null
vs_ipc dock position bottom >/dev/null
opened=""
for n in 4 3 5 2 6; do
  vs_pointer abs 1000 600 rclick >/dev/null
  vs_sleep 0.8
  for _ in $(seq 1 "$n"); do fl_tap Down; done
  fl_tap Return
  vs_sleep 1
  if [[ $(fl_notif center) == true ]]; then opened=$n; break; fi
  fl_tap Escape
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
fl_check "Edit Widgets... opens the gallery (menu row Down x${opened:-?})" test -n "$opened"
vs_sleep 2
fl_shot gallery >/dev/null
fl_tap Escape
vs_sleep 0.5
if [[ $(fl_notif center) == true ]]; then vs_ipc notifications toggleCenter >/dev/null; fi
fl_check_wait "the gallery is closed" 5 test "$(fl_notif center)" = false

# ---- 3, 4, 10. input source and brightness OSD ---------------------------------------------------------------
vs_ipc osd hide >/dev/null
vs_ipc osd layout "kbd0,English (US)" >/dev/null
vs_ipc osd layout "kbd0,German" >/dev/null
fl_wait 6 test "$(vs_ipc osd state | tr -d '"' | cut -d'|' -f1)" = true
st=$(vs_ipc osd state | tr -d '"')
echo "osd state after a layout change: $st"
fl_check "French: the input source HUD names the layout in French (state $st)" test "${st#*|inputsource|}" = "Allemand"
fl_shot inputsource >/dev/null
vs_ipc osd hide >/dev/null
vs_ipc osd layout "wtype,error" >/dev/null
vs_sleep 0.5
st=$(vs_ipc osd state | tr -d '"')
fl_check "a virtual keyboard's error shows nothing (state $st)" test "${st%%|*}" = false
"$VS_ROOT/scripts/dev/keys.sh" "a" >/dev/null 2>&1
vs_sleep 1
st=$(vs_ipc osd state | tr -d '"')
fl_check "typing through the virtual keyboard shows no HUD (state $st)" test "${st#*|inputsource|}" != "error"
fl_check "the shell log never names the layout error" test "$(grep -c 'inputsource|error' "$VS_DEV/shell.log")" = 0

# ---- the four apps, a folder with two windows ---------------------------------------------------------------------
vs_spawn "$b/grassfield-files" "$VS_FILES"
vs_spawn "$b/grassfield-files" "$img"
vs_spawn "$b/grassfield-settings"
vs_spawn "$b/grassfield-preview" "$img/img1.png"
vs_spawn "$b/grassfield-activity"
files='org\.grassfield\.Files'
two_files() { [[ $(fl_window_count "$files") -ge 2 ]]; }
fl_check_wait "two Files windows" 40 two_files
fl_check_wait "Settings opens" 40 fl_has_window 'org\.grassfield\.Settings'
fl_check_wait "Preview opens" 40 fl_has_window '^org\.grassfield\.Preview$'
fl_check_wait "Activity Monitor opens" 40 fl_has_window 'org\.grassfield\.Activity'
vs_sleep 3
echo "windows: $(fl_clients '.' | cut -f2,3 | paste -sd';' -)"

# 6. the switcher
vs_ipc switcher next 1 >/dev/null
vs_sleep 1.5
sw=$(vs_ipc switcher status | jq -r . 2>/dev/null || vs_ipc switcher status)
echo "switcher status: $sw"
for app in Files Settings Preview Activity; do
  fl_check "the switcher lists $app" bash -c "grep -q 'org.grassfield.$app' <<<'$sw'"
done
fl_shot switcher >/dev/null
vs_ipc switcher cancel >/dev/null
vs_sleep 1
tiles=$(vs_ipc dock tiles)
echo "dock tiles: $tiles"

# 9. the Window menu and a Dock menu with a checked window
fl_focus_class "$files" >/dev/null
vs_sleep 1
vs_ipc menubar open appwindow "$VS_OUTPUT" >/dev/null
vs_sleep 1.5
fl_shot window-menu >/dev/null
vs_ipc menubar close >/dev/null
vs_sleep 0.5
# Files' own File menu through the menu bridge: the shortcuts are in French (Qt's names: Ctrl+Backspace -> Ctrl+Retour arriere).
vs_pointer abs 146 12 click >/dev/null
vs_sleep 1.5
fl_shot file-menu >/dev/null
vs_ipc menubar close >/dev/null
vs_sleep 0.5
idx=$(vs_ipc dock tiles | jq -r 'index("files")')
echo "files tile index: $idx"
if [[ $idx != null && -n $idx ]]; then
  vs_ipc dock menu "$idx" "$VS_OUTPUT" >/dev/null
  vs_sleep 1.5
  fl_shot dock-menu >/dev/null
  vs_ipc menubar close >/dev/null
fi

# 7. Glance on top of Preview: no Dock tile, the bar keeps naming Preview
fl_focus_class '^org\.grassfield\.Preview$' >/dev/null
vs_sleep 1
fl_shot before-glance >/dev/null
vs_spawn "$b/grassfield-preview" --glance -- "$img/img2.png"
fl_check_wait "Glance opens" 30 fl_has_window 'Preview\.Glance'
vs_sleep 2
fl_check "Glance has the focus" fl_active_is 'Preview\.Glance'
tiles=$(vs_ipc dock tiles)
echo "dock tiles with Glance: $tiles"
fl_check "no Dock tile for Glance" test "$(grep -ci glance <<<"$tiles")" = 0
fl_shot glance >/dev/null

fl_tap Escape
vs_sleep 1

# 7b. Glance opened from the desktop (the desktop holds the keyboard, then Glance is clicked): the bar stays on the desktop
vs_pointer abs 250 600 click >/dev/null
vs_sleep 1
vs_spawn "$b/grassfield-preview" --glance -- "$img/img1.png"
fl_check_wait "Glance opens from the desktop" 30 fl_has_window 'Preview\.Glance'
vs_sleep 2
fl_focus_class 'Preview\.Glance' >/dev/null
vs_sleep 1
fl_shot glance-desktop >/dev/null
fl_tap Escape
vs_sleep 1

# 8. a stack in Grid view with long names
fix=$VS_DEV/stackfix
rm -rf "$fix"
mkdir -p "$fix"
for n in "Présentation.odp" "Rapport annuel 2025 final version definitive.pdf" "Photo de vacances.jpg" "Présentationtrimestrielledevente.odp" "Documents" "notes.txt"; do
  printf 'x' > "$fix/$n"
done
cfg=$VS_DEV/config/grassfield.json
mkdir -p "$(dirname "$cfg")"
[[ -s $cfg ]] || echo '{"version":1}' >"$cfg"
tmp=$(mktemp "$cfg.XXXXXX") && jq ".dock.folders = [\"$fix\"] | .dock.stackOptions = {\"$fix\": {\"view\": \"grid\"}}" "$cfg" >"$tmp" && mv "$tmp" "$cfg"
sleep 1.5
idx=$(vs_ipc dock tiles | jq -r --arg k "$fix" 'index($k)')
fl_check "the stack folder is a Dock tile (index $idx)" test "$idx" != null
vs_ipc dock stack "$idx" "$VS_OUTPUT" >/dev/null
vs_sleep 2
fl_shot stack-grid >/dev/null
fl_tap Escape

fl_done
