#!/usr/bin/env bash
# GF-009 functional flow: the Files app, used the way a user does. Nested session only.
#
# Proves, with the windows the compositor reports and the files on disk:
#   1. Files opens a folder; opening a sub-folder (type to select, Ctrl+Down: Return renames, as in the Finder) and going
#      up (Ctrl+Up) follows in the title;
#   2. Get Info (Ctrl+I) opens an info window for the selected file, and Ctrl+W there closes it alone;
#   3. New Folder (Ctrl+Shift+N) creates a folder named in place; Rename (F2) renames a file;
#   4. a file is moved into the new folder (Cut, open the folder, Paste);
#   5. Move to Trash (Ctrl+Backspace) moves it to the SANDBOX Trash (never the owner's: counted before and after);
#   6. Ctrl+W on the last window ends the app, and the app log holds no QML error.
# Isolation (the model of tests/apps/files_sandbox.sh, whose reasons apply as they are): every file lives under
# .dev/visual/files-flow; the app runs through scripts/dev/isolated.sh (XDG directories under .dev/isolated/files-flow, so
# its Trash is a sandbox Trash) on a PRIVATE session bus started here with the same isolated homes and the nested Wayland
# socket, so whatever KIO activates is isolated too; the script refuses an address that could be the owner's bus.
# Requires: .dev/build/grassfield-files (apps/files/build-direct.sh), dbus-daemon.
# Captures: $VS_SHOTS/flow-files-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up its window and bus):  tests/visual/flow-files.sh
# Expected: a PASS line per check and "files: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start files

bin=$VS_DEV/build/grassfield-files
[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
type -P dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not found"; exit 1; }

work=$VS_STATE/files-flow
top=$work/top
busdir=$work/.bus
iso_name=files-flow
iso=$VS_DEV/isolated/$iso_name
log=$VS_DEV/files-flow.log
trash=$iso/data/Trash
case $work in "$VS_ROOT"/.dev/visual/files-flow) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$VS_ROOT"/.dev/isolated/files-flow) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac
rm -rf -- "$work" "$iso"
mkdir -p "$top/Documents" "$top/Pictures" "$busdir" "$iso"/{home,config,cache,state,data}
printf 'quarterly numbers\n' >"$top/report.txt"
printf 'meeting notes\n' >"$top/Documents/notes.txt"

env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY="$(vs_nested_wayland)" GRASSFIELD_DEV=1 HOME="$iso/home" \
  XDG_CONFIG_HOME="$iso/config" XDG_CACHE_HOME="$iso/cache" XDG_STATE_HOME="$iso/state" XDG_DATA_HOME="$iso/data" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
bus_start=$(dev_start_time "$bus_pid" || echo none)
app=""
app_start=none
# Signal a process group only while the pid still is the process started here (start time, scripts/dev/pidfile.sh) and
# dev_may_signal allows it (never a compositor, this script or its parents).
stop_group() { # PID START
  [[ -n $1 && $(dev_start_time "$1" 2>/dev/null) == "$2" ]] && dev_may_signal "$1" && kill -- "-$1" 2>/dev/null
  return 0
}
files_cleanup() {
  stop_group "$app" "$app_start"
  stop_group "$bus_pid" "$bus_start"
  [[ -n $app ]] && wait "$app" 2>/dev/null
  wait "$bus_pid" 2>/dev/null
  fl_cleanup
}
trap files_cleanup EXIT
for _ in $(seq 1 50); do [[ -s $busdir/address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$busdir/address" 2>/dev/null)
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "FAIL: refusing: the private bus did not start or has an unexpected address '$bus' (see $busdir/log)"; exit 1 ;;
esac
[[ $bus != "$owner_bus" && $bus != "unix:path=${XDG_RUNTIME_DIR:-}/bus"* ]] || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }
kill -0 "$bus_pid" 2>/dev/null || { echo "FAIL: the private bus exited (see $busdir/log)"; exit 1; }
echo "files: private bus $bus (pid $bus_pid)"

owner_trash=$HOME/.local/share/Trash/files
owner_before=$( [[ -d $owner_trash ]] && find "$owner_trash" -mindepth 1 -maxdepth 1 | wc -l || echo 0)

class='org\.grassfield\.Files'
title_is() { fl_title_has "$class" "$1"; }
files_windows() { fl_window_count "$class"; }
more_windows() { [[ $(files_windows) -gt $1 ]]; }
settle() { vs_sleep 1.5; files_ready >/dev/null; } # the type-to-select buffer expires after about a second; the keyboard is back in Files

# Open the app on the folder; the window opens on the output under the pointer, so click the empty desktop first.
vs_pointer abs 960 540 sleep 100 click >/dev/null
env -u HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$VS_ROOT/ui" QT_FORCE_STDERR_LOGGING=1 \
  QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$(vs_nested_wayland)" \
  setsid "$VS_ROOT/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$top" >"$log" 2>&1 </dev/null &
app=$!
app_start=$(dev_start_time "$app" || echo none)
fl_check_wait "Files opens the folder (title names 'top')" 25 title_is '(^|[^a-z])top'
vs_sleep 2
# Focus: the keyboard must be in the Files window before anything is typed (otherwise the desktop icons get the keys).
files_ready() { fl_focus_class "$class"; }
fl_check "Files has the keyboard focus" files_ready
vs_sleep 0.6
fl_shot top >/dev/null

# 1. open a folder and go back up
settle
fl_type Documents
fl_appkey ctrl Down
fl_check_wait "Ctrl+Down opens the Documents folder (title)" 10 title_is 'Documents'
fl_shot documents >/dev/null
fl_appkey ctrl Up
fl_check_wait "Ctrl+Up goes back to the parent folder" 10 title_is '(^|[^a-z])top'

# 2. Get Info
settle
fl_type report
before=$(files_windows)
fl_appkey ctrl i
fl_check_wait "Ctrl+I opens an info window for report.txt" 10 more_windows "$before"
fl_check_wait "the info window is named after the file" 5 title_is 'report'
fl_shot info >/dev/null
fl_appkey ctrl w
# Ctrl+W closes the key window only (macOS): one window fewer, and that one was the info window. The browser window (its
# title names 'top') is still there and the app still runs; a count that merely dropped would also pass when the browser
# closed and took the info window with it.
info_closed_alone() { kill -0 "$app" 2>/dev/null && [[ $(files_windows) -eq $1 ]] && title_is '(^|[^a-z])top'; }
fl_check_wait "Ctrl+W closes the info window alone (the browser window stays open)" 10 info_closed_alone "$before"
settle

# 3. New Folder, Rename
fl_appkey ctrl+shift n
fl_check_wait "Ctrl+Shift+N creates 'untitled folder'" 5 test -d "$top/untitled folder"
vs_sleep 1
fl_type Projects
fl_key -k Return
fl_check_wait "the new folder is named in place (Projects)" 5 test -d "$top/Projects"
settle
fl_type report
fl_key -k F2
fl_type summary
fl_key -k Return
fl_check_wait "F2 renames report.txt to summary.txt" 5 test -f "$top/summary.txt"
fl_check "report.txt is gone" test ! -e "$top/report.txt"
fl_shot renamed >/dev/null

# 4. Move into the new folder: Cut, open Projects, Paste
settle
fl_type summary
fl_appkey ctrl x
settle
fl_type Projects
fl_appkey ctrl Down
fl_check_wait "Projects is open" 10 title_is 'Projects'
fl_appkey ctrl v
fl_check_wait "Cut and Paste moved summary.txt into Projects" 8 test -f "$top/Projects/summary.txt"
fl_check "and it left the parent folder" test ! -e "$top/summary.txt"
fl_shot moved >/dev/null

# 5. Move to Trash (the pasted file is selected)
settle
fl_type summary
fl_appkey ctrl BackSpace
fl_check_wait "Ctrl+Backspace moves summary.txt out of Projects" 8 test ! -e "$top/Projects/summary.txt"
fl_check_wait "it is in the SANDBOX Trash" 5 test -f "$trash/files/summary.txt"
fl_check "the Trash has its .trashinfo" test -f "$trash/info/summary.txt.trashinfo"
fl_shot trashed >/dev/null

# 6. Ctrl+W ends the app
fl_appkey ctrl w
gone() { ! kill -0 "$app" 2>/dev/null; }
fl_check_wait "Ctrl+W on the last window ends the app" 10 gone
owner_after=$( [[ -d $owner_trash ]] && find "$owner_trash" -mindepth 1 -maxdepth 1 | wc -l || echo 0)
fl_check "the owner's Trash is untouched ($owner_before -> $owner_after entries)" test "$owner_before" = "$owner_after"
launches=$(grep -c "launch blocked" "$log" || true)
fl_check "no application launch was attempted ($launches)" test "$launches" = 0
errors=$(grep -E "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log" | grep -vcE "qml: grassfield: global menu (created|destroyed)" || true)
fl_check "the app log has no QML errors or warnings ($errors lines)" test "$errors" = 0

fl_done
