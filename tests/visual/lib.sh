#!/usr/bin/env bash
# Shared helpers for tests/visual scenarios (source it; do not run it).
#
# Determinism contract (docs/testing/visual.md): nested session on a private D-Bus, reference output GF-REF
# (1920x1080, scale 1), frozen clock, fixed fixtures on the desktop, transparency 0.25, dark appearance,
# reduce-motion on (no animation in flight at capture time), pointer parked at a fixed spot.
#
# Every scenario must be started as a BARE command (Claude Code sandbox exclusion); helpers below call the
# dev scripts as child processes.

set -euo pipefail

VS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VS_ROOT=$(cd "$VS_HERE/../.." && pwd)
VS_DEV=$VS_ROOT/.dev
VS_STATE=$VS_DEV/visual
VS_SHOTS=${VISUAL_SHOTS:-$VS_STATE/shots}
VS_LANG=${VISUAL_LANG:-en}
VS_OUTPUT=GF-REF
VS_FIXED_TIME="2026-10-17T09:41:00"
VS_PARK_X=200
VS_PARK_Y=700

# Stable absolute path: the Files breadcrumb shows it (not under the worktree).
VS_FILES=/tmp/grassfield-visual/files-sandbox

mkdir -p "$VS_STATE" "$VS_SHOTS"

vs_ipc() { "$VS_HERE/ipc.sh" "$@"; }
vs_pointer() { "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" "$@"; }
vs_sleep() { sleep "${1:-0.5}"; }

vs_nested_wayland() { cat "$VS_DEV/nested.wayland"; }

vs_nested_running() {
  [[ -s $VS_DEV/nested.pid ]] && kill -0 "$(<"$VS_DEV/nested.pid")" 2>/dev/null
}

# Desktop fixture folder (never the owner's real desktop): fixed names, fixed content.
vs_fixtures() {
  local d=$VS_STATE/desktop
  mkdir -p "$d"
  if [[ ! -f $d/Notes.txt ]]; then
    printf 'Grassfield visual fixture\n' > "$d/Notes.txt"
    printf 'Quarterly report\n' > "$d/Report.md"
    printf 'x\n' > "$d/Archive.zip"
    mkdir -p "$d/Projects"
  fi
  # Files scenario folder.
  local f=$VS_FILES
  mkdir -p "$f/Documents" "$f/Pictures" "$f/Music"
  if [[ ! -f $f/readme.txt ]]; then
    printf 'hello\n' > "$f/readme.txt"
    printf 'a,b\n1,2\n' > "$f/table.csv"
    printf '#!/bin/sh\n' > "$f/script.sh"
  fi
  # Fixed mtimes: the Files list shows modification dates.
  touch -d "2026-10-01 12:00:00" "$f"/readme.txt "$f"/table.csv "$f"/script.sh "$f"/Documents "$f"/Pictures "$f"/Music
}

# Make sure a nested session with the shell in language $1 (default $VS_LANG) is up. Idempotent.
vs_session() {
  local lang=${1:-$VS_LANG} cur=""
  vs_fixtures
  export GRASSFIELD_FIXED_TIME=$VS_FIXED_TIME
  export LC_ALL=en_US.UTF-8
  export GRASSFIELD_DESKTOP_SCREEN=$VS_OUTPUT
  export GRASSFIELD_SEARCH_ROOT=$VS_FILES
  # Dev state/config of THIS worktree only (never the owner's): defaults, no notification history.
  rm -rf "$VS_DEV/state/"* "$VS_DEV/config/"* 2>/dev/null || true
  [[ -f $VS_STATE/session.lang ]] && cur=$(<"$VS_STATE/session.lang")
  if ! vs_nested_running; then
    "$VS_ROOT/scripts/dev/nested-up.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop"
    printf '%s\n' "$lang" > "$VS_STATE/session.lang"
  elif [[ -z ${VS_REUSE:-} || $cur != "$lang" ]] || ! vs_ipc lock status >/dev/null 2>&1; then
    # A fresh shell per scenario: no banner, popup or notification history leaks between scenarios.
    "$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop"
    printf '%s\n' "$lang" > "$VS_STATE/session.lang"
  fi
  local i
  for i in $(seq 1 60); do
    vs_ipc lock status >/dev/null 2>&1 && break
    sleep 0.5
  done
  vs_ipc lock status >/dev/null 2>&1 || { echo "visual: shell did not come up (see .dev/shell.log)" >&2; return 1; }
  sleep 2
}

# PIDs of client processes started by scenarios (killed by vs_reset; never anything else).
vs_track() { printf '%s\n' "$1" >> "$VS_STATE/pids"; }

vs_kill_clients() {
  [[ -f $VS_STATE/pids ]] || return 0
  local p
  while read -r p; do
    [[ -n $p ]] && kill "$p" 2>/dev/null || true
  done < "$VS_STATE/pids"
  : > "$VS_STATE/pids"
  sleep 0.7
}

# Run a client on the nested compositor only (WAYLAND_DISPLAY = nested socket, private bus if recorded).
vs_spawn() {
  local sock bus=""
  sock=$(vs_nested_wayland)
  [[ -f $VS_DEV/bus.address ]] && bus=$(<"$VS_DEV/bus.address")
  env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="${bus:-}" LC_ALL=en_US.UTF-8 \
    QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$VS_ROOT/ui:$VS_DEV/build/qml" \
    GRASSFIELD_TRANSLATIONS_DIR="$VS_DEV/translations" GRASSFIELD_LANG="$(<"$VS_STATE/session.lang")" \
    HYPRLAND_INSTANCE_SIGNATURE="$(<"$VS_DEV/nested.instance")" "$@" >/dev/null 2>&1 </dev/null &
  vs_track "$!"
}

# Known state: no popups, no clients, dark, transparency 0.25, motion reduced, pointer parked on GF-REF.
vs_reset() {
  local appearance=${1:-dark} transparency=${2:-0.25}
  vs_kill_clients
  vs_ipc menubar close >/dev/null || true
  vs_ipc search close >/dev/null || true
  vs_ipc apps close >/dev/null || true
  vs_ipc overview close >/dev/null || true
  vs_ipc dock unhover >/dev/null || true
  vs_ipc wallpaper set "" >/dev/null || true
  vs_ipc controlcenter appearance "$appearance" >/dev/null
  vs_ipc controlcenter transparency "$transparency" >/dev/null
  vs_ipc controlcenter reduceTransparency false >/dev/null
  vs_ipc controlcenter reduceMotion true >/dev/null
  vs_ipc notifications dnd false >/dev/null || true
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
  vs_sleep 0.8
}

# vs_capture NAME: GF-REF screenshot → $VS_SHOTS/NAME.<lang>.png
vs_capture() {
  local name=$1
  vs_sleep "${VS_SETTLE:-1}"
  "$VS_ROOT/scripts/dev/shot.sh" "visual-$name" "$VS_OUTPUT" >/dev/null
  cp "$VS_DEV/shots/visual-$name.png" "$VS_SHOTS/$name.$VS_LANG.png"
  # VS_MASK="x1,y1,x2,y2 ...": black out machine-dependent text (free disk space, ...).
  local r
  for r in ${VS_MASK:-}; do
    IFS=, read -r x1 y1 x2 y2 <<<"$r"
    magick "$VS_SHOTS/$name.$VS_LANG.png" -fill black -draw "rectangle $x1,$y1 $x2,$y2" "$VS_SHOTS/$name.$VS_LANG.png"
  done
  echo "$VS_SHOTS/$name.$VS_LANG.png"
}

# Three test notifications on the private bus.
vs_notify() {
  local bus
  bus=$(<"$VS_DEV/bus.address")
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 0 "Design review" "Starts in 10 minutes in Room 4."
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 0 "Anna Martin" "Are we still on for lunch tomorrow?"
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Software Update" -t 0 "Updates available" "3 updates are ready to install."
}

# Number of client windows in the nested compositor (read-only query).
vs_client_count() { "$VS_ROOT/scripts/nestctl" clients -j | jq 'length'; }

vs_wait_clients() {
  local want=$1 i
  for i in $(seq 1 40); do
    [[ $(vs_client_count) -ge $want ]] && { sleep 1; return 0; }
    sleep 0.5
  done
  echo "visual: expected $want windows, have $(vs_client_count)" >&2
  return 1
}

# vs_foot TITLE COLSxROWS: a foot window with the fixed configuration and fixed content.
vs_foot() {
  local title=$1 size=$2
  vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" -T "$title" --window-size-chars "$size" \
    sh -c "printf '%s\\n' '$title' 'Grassfield visual fixture' '0123456789 abcdefghij ABCDEFGHIJ'; exec sleep 100000"
}
