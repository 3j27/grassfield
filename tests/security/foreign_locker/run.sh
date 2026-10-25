#!/usr/bin/env bash
# Starts the foreign locker fixture (ForeignLocker.qml) only when a Wayland socket to connect to exists. Quickshell
# without a display aborts in QGuiApplication (SIGABRT, a core dump, a "quit unexpectedly" banner in the owner's session,
# seen on 2026-10-25 from a probe started without WAYLAND_DISPLAY). Here a missing display is a plain exit 2 (skip) instead.
# The fixture needs a real compositor (it takes an ext-session-lock): offscreen is no substitute, so the platform is forced
# to wayland. Nested instances only; the callers check that the socket is the nested one.
#   tests/security/foreign_locker/run.sh [qs arguments after -p <this directory's ForeignLocker.qml>]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sock=${WAYLAND_DISPLAY:-}
if [[ -z $sock ]]; then
  echo "foreign locker: WAYLAND_DISPLAY is not set, not starting (no display)" >&2
  exit 2
fi
if [[ $sock == /* ]]; then path=$sock; else path=${XDG_RUNTIME_DIR:-/nonexistent}/$sock; fi
if [[ ! -S $path ]]; then
  echo "foreign locker: no Wayland socket at $path, not starting" >&2
  exit 2
fi
export QT_QPA_PLATFORM=wayland
exec qs -p "$here/ForeignLocker.qml" "$@"
