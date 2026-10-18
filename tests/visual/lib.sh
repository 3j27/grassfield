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
# Pointer parking (vs_park): a fixed spot on GF-REF in the left margin, where no scenario surface (Apps cell, Dock
# tile, Search row, popup menu, window, Overview thumbnail) extends, so no hover state is a race. The cursor is part
# of the screenshot; its position is fixed. (A second nested output would be better still, but a pointer there
# takes the focus away from focus-bound surfaces such as Search, Apps and the notification banners.)
VS_PARK_X=24
VS_PARK_Y=540

# Files sandbox folder: under this worktree's .dev/visual (never /tmp: fixed and shared between worktrees). The
# breadcrumb shows the absolute path; those pixels are masked (VS_MASK) in files.sh, see docs/testing/visual.md. The Search
# scenario shows no path (the Files row subtitle is "Application"), so nothing in it is masked.
VS_FILES=$VS_STATE/files-sandbox

mkdir -p "$VS_STATE" "$VS_SHOTS"

vs_ipc() { "$VS_HERE/ipc.sh" "$@"; }
vs_pointer() { "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" "$@"; }
vs_sleep() { sleep "${1:-0.5}"; }

# Park the pointer on the fixed spot of GF-REF, then let hover state settle (VS_HOVER_SETTLE seconds).
vs_park() {
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
  vs_sleep "${VS_HOVER_SETTLE:-0.8}"
}

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

# Wait (at most 30 s) until the nested compositor has the reference output GF-REF; fail otherwise.
vs_wait_output() {
  local i
  for i in $(seq 1 60); do
    "$VS_ROOT/scripts/nestctl" monitors -j 2>/dev/null | jq -e --arg n "$VS_OUTPUT" 'any(.[]; .name == $n)' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "visual: output $VS_OUTPUT did not appear in the nested compositor" >&2
  return 1
}

# Which monitor gets Space 1 depends on whether the nested window's output (WAYLAND-1) or the headless GF-REF is
# created first, which races with the load of the owner's session: the Spaces bar then reads "Desktop 1" in one run
# and "Desktop 2" in the next. The reference state is GF-REF on Space 2 (WAYLAND-1 on 1, as in a quiet session); any
# other assignment restarts the nested session (at most 4 starts).
vs_canonical_workspaces() {
  local lang=$1 n i ws
  for n in 1 2 3 4; do
    sleep 2
    ws=$("$VS_ROOT/scripts/nestctl" monitors -j 2>/dev/null | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .activeWorkspace.id' 2>/dev/null || true)
    [[ $ws == 2 ]] && return 0
    echo "visual: $VS_OUTPUT is on Space '${ws:-?}', not 2: restarting the nested session ($n/4)" >&2
    "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
    "$VS_ROOT/scripts/dev/nested-up.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop" || return 1
    vs_wait_output || return 1
  done
  echo "visual: $VS_OUTPUT never got Space 2 in 4 nested starts" >&2
  return 1
}

# Make sure a nested session with the shell in language $1 (default $VS_LANG) is up. Idempotent.
vs_session() {
  local lang=${1:-$VS_LANG} cur=""
  vs_fixtures
  export GRASSFIELD_FIXED_TIME=$VS_FIXED_TIME
  export GRASSFIELD_VISUAL_FIXTURES=1  # fixed Wi-Fi/Bluetooth/user/battery (shell/services/VisualFixtures.qml, dev only)
  export LC_ALL=en_US.UTF-8
  export GRASSFIELD_DESKTOP_SCREEN=$VS_OUTPUT
  export GRASSFIELD_SEARCH_ROOT=$VS_FILES
  # Dev state/config of THIS worktree only (never the owner's): defaults, no notification history.
  rm -rf "$VS_DEV/state/"* "$VS_DEV/config/"* "$VS_DEV/isolated/visual" 2>/dev/null || true
  [[ -f $VS_STATE/session.lang ]] && cur=$(<"$VS_STATE/session.lang")
  if ! vs_nested_running; then
    "$VS_ROOT/scripts/dev/nested-up.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop"
    # nested-up starts the shell at once, before the headless GF-REF output exists (Hyprland creates it from its start
    # callback): the shell then logs "Layershell screen does not correspond to a real screen" and the desktop icons and
    # the other GF-REF surfaces are missing. Wait for GF-REF, then (re)start the shell on it.
    vs_wait_output || return 1
    vs_canonical_workspaces "$lang" || return 1
    "$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop"
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
  vs_wait_capabilities "$lang" || return 1
  sleep 2
}

# The shell decides v1/v2 Overview, titlebars and the desktop focus policy from the plugin's capabilities, which arrive
# after the shell is up (hello reply). A capture taken before they arrive differs from one taken after, so wait for
# `capabilities status` = "ready present ..." when the plugin is loaded in the nested session; "ready degraded" is
# the expected state without it. A shell that settled degraded although the plugin is there (its hello retries ended
# before the plugin answered) is restarted once.
vs_plugin_expected() {
  [[ -f ${GRASSFIELD_PLUGIN:-$VS_ROOT/compositor/build/grassfield-compositor.so} && -z ${GRASSFIELD_NO_PLUGIN:-} ]]
}

vs_wait_capabilities() {
  local lang=$1 i st="" attempt
  for attempt in 1 2; do
    for i in $(seq 1 60); do
      st=$(vs_ipc capabilities status 2>/dev/null || true)
      case $st in
        "ready present"*) return 0 ;;
        "ready degraded") vs_plugin_expected || return 0; break ;;
      esac
      sleep 0.5
    done
    (( attempt == 1 )) || break
    "$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$lang" --desktop-dir "$VS_STATE/desktop"
    for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
  done
  echo "visual: capabilities not ready (last status: ${st:-none}); the compositor plugin did not answer" >&2
  return 1
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
  # scripts/dev/isolated.sh: XDG_* and GRASSFIELD_*_HOME under .dev/ (config/state shared with the nested shell,
  # so an app shows the settings the shell wrote), never the owner's home.
  "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
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
  vs_wallpaper "" || true
  vs_ipc visual glyphs normal >/dev/null || true
  vs_ipc controlcenter appearance "$appearance" >/dev/null
  vs_ipc controlcenter transparency "$transparency" >/dev/null
  vs_ipc controlcenter reduceTransparency false >/dev/null
  vs_ipc controlcenter reduceMotion true >/dev/null
  vs_ipc notifications dnd false >/dev/null || true
  vs_park
}

# vs_capture NAME: GF-REF screenshot → $VS_SHOTS/NAME.<lang>.png
vs_capture() {
  local name=$1
  [[ -n ${VS_NOPARK:-} ]] || vs_park
  vs_sleep "${VS_SETTLE:-1}"
  # Park again immediately before the capture (a window mapping under the pointer or a focus change during the settle
  # can move the software cursor: files.fr differed by 84 px between two runs) and wait a few frames.
  [[ -n ${VS_NOPARK:-} ]] || { vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null; vs_sleep 0.2; }
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

# vs_wallpaper PATH: cover the artwork with an image (dev IPC validates it: absolute .png/.jpg/.jpeg regular file
# under 64 MB) and wait for the outcome; "" restores the artwork. Fails with the refusal reason.
vs_wallpaper() {
  local r i
  r=$(vs_ipc wallpaper set "$1") || return 1
  if [[ $r == validating ]]; then
    for i in $(seq 1 40); do
      r=$(vs_ipc wallpaper status)
      [[ $r == validating ]] || break
      sleep 0.1
    done
  fi
  case $r in
    ok|applied) return 0 ;;
    *) echo "visual: wallpaper $1: $r" >&2; return 1 ;;
  esac
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
