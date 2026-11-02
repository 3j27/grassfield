#!/usr/bin/env bash
# ADR-0041 step 6a: the liveness probe's question and its dev hook, offscreen, on the installed Quickshell and the real
# Capabilities singleton (tests/shell/shell_watchdog_hook.d/probe.qml). In a dev session `capabilities status` answers;
# `capabilities devBlock 4` blocks the GUI thread for 4 s, during which the same question gets no answer within 2 s (what
# grassfield-shell-watchdog counts as a miss), and after which it answers again. Outside a dev session devBlock is refused at
# once and blocks nothing, and status answers `refused`, which the probe takes as the shell alive.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. SKIP without Quickshell.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: shell_watchdog_hook: Quickshell (qs) is not installed"; exit 0; }
fail=0
check() { if "$@"; then echo "PASS: shell_watchdog_hook $desc"; else echo "FAIL: shell_watchdog_hook $desc"; fail=1; fi; }
tmp=$(mktemp -d "$root/.dev/watchdog-hook.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/watchdog-hook.XXXXXX"; })
# The runtime folder (Quickshell's IPC sockets) under a short base: a Unix socket path holds at most 107 bytes.
rt=$(mktemp -d "${TMPDIR:-/tmp}/gf-rt.XXXXXX")
chmod 700 "$rt"
probe=""
trap '[[ -n $probe ]] && kill "$probe" 2>/dev/null; rm -rf "$tmp" "$rt"' EXIT
mkdir -p "$tmp/cfg" "$tmp/state" "$tmp/config" "$tmp/cache" "$tmp/home"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/shell_watchdog_hook.d/probe.qml "$tmp/cfg/shell.qml"
ui/i18n/build-direct.sh >/dev/null

start() { # <dev: 1 or 0>: the probe shell in the background, ready or not within 20 s
  local dev=() i
  [[ $1 == 1 ]] && dev=(GRASSFIELD_DEV=1)
  : >"$tmp/out"
  env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u GRASSFIELD_DEV -u DBUS_SESSION_BUS_ADDRESS -u HYPRLAND_INSTANCE_SIGNATURE "${dev[@]}" \
    HOME="$tmp/home" GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" XDG_RUNTIME_DIR="$rt" XDG_CACHE_HOME="$tmp/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" qs -p "$tmp/cfg" --no-color >"$tmp/out" 2>&1 &
  probe=$!
  for i in $(seq 200); do
    grep -q "watchdog-hook: ready" "$tmp/out" && return 0
    kill -0 "$probe" 2>/dev/null || break
    sleep 0.1
  done
  echo "FAIL: shell_watchdog_hook the probe shell did not start"; tail -20 "$tmp/out"; fail=1
  return 1
}
stop() { [[ -n $probe ]] && kill "$probe" 2>/dev/null; wait "$probe" 2>/dev/null; probe=""; }
ask() { # <seconds> <function> [args]: the answer on stdout, timeout's exit code in $rc
  local s=$1
  shift
  rc=0
  env -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$rt" \
    timeout -k 0.5 "$s" qs ipc -p "$tmp/cfg" call capabilities "$@" 2>/dev/null || rc=$?
}

if start 1; then
  answer=$(ask 5 status)
  desc="dev session: the question answers (\"$answer\")"
  check test "$rc" = 0 -a -n "$answer"
  ask 15 devBlock 4 >"$tmp/blocked" &
  blocker=$!
  sleep 0.5
  ask 2 status >/dev/null
  desc="while devBlock holds the GUI thread the question gets no answer within 2 s (timeout's exit 124, a miss)"
  check test "$rc" = 124
  wait "$blocker"
  desc="devBlock answers once its 4 s are over"
  check test "$(cat "$tmp/blocked")" = "blocked 4"
  answer=$(ask 5 status)
  desc="after the block the question answers again"
  check test "$rc" = 0 -a -n "$answer"
  stop
fi
if start 0; then
  before=$(date +%s)
  answer=$(ask 5 devBlock 4)
  desc="outside a dev session devBlock is refused at once and blocks nothing"
  check test "$rc" = 0 -a "$answer" = refused -a $(($(date +%s) - before)) -le 2
  answer=$(ask 5 status)
  desc="outside a dev session the question answers refused, which the probe takes as the shell alive"
  check test "$rc" = 0 -a "$answer" = refused
  stop
fi
exit $fail
