#!/usr/bin/env bash
# Lid and clamshell (macOS model): packaging/bin/grassfield-lid against fake /proc and /sys trees and a fake hyprctl.
#  * lid closed, no external display: lock (logind suspends), the laptop panel is left alone;
#  * lid closed with an external display: no lock, the laptop panel is switched off (the computer keeps running);
#  * lid opened, or the external display unplugged while closed: the user's monitor configuration is applied again;
#  * every call is idempotent.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/lid.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/proc/LID0" "$tmp/drm/card1-eDP-1" "$tmp/drm/card1-DP-3" "$tmp/drm/card1-HDMI-A-1" "$tmp/run"
printf '#!/bin/sh\necho "hyprctl $*" >>"$FAKE_DIR/calls.log"\n' >"$tmp/bin/hyprctl"
printf '#!/bin/sh\necho "lock" >>"$FAKE_DIR/calls.log"\n' >"$tmp/bin/lock"
chmod +x "$tmp/bin/hyprctl" "$tmp/bin/lock"

setup() { # setup <lid open|closed> <DP-3 connected|disconnected>
  printf 'state:      %s\n' "$1" >"$tmp/proc/LID0/state"
  printf '%s\n' connected >"$tmp/drm/card1-eDP-1/status"
  printf '%s\n' "$2" >"$tmp/drm/card1-DP-3/status"
  printf '%s\n' disconnected >"$tmp/drm/card1-HDMI-A-1/status"
}
lid() {
  FAKE_DIR=$tmp PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR=$tmp/run GRASSFIELD_LID_PROC=$tmp/proc GRASSFIELD_DRM=$tmp/drm \
    GRASSFIELD_LID_LOCK="$tmp/bin/lock" bash "$root/packaging/bin/grassfield-lid" "$@"
}
reset() { : >"$tmp/calls.log"; }
calls() { cat "$tmp/calls.log"; }

desc="lid closed, no external display: the screen is locked and the laptop panel is not touched"
reset; setup closed disconnected; lid closed
check bash -c 'grep -qx lock "$1/calls.log" && ! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="lid closed with an external display: not locked, the laptop panel (eDP-1) is switched off"
reset; setup closed connected; lid closed
check bash -c '! grep -qx lock "$1/calls.log" && grep -q "hyprctl eval hl.monitor({ output = \"eDP-1\", disabled = true })" "$1/calls.log"' _ "$tmp"

desc="repeated events do not switch it off again (idempotent)"
reset; lid reconcile; lid closed
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="lid opened: the user's monitor configuration is applied again (reload), once"
reset; setup open connected; lid opened; lid reconcile
check bash -c '[[ $(grep -c "hyprctl reload" "$1/calls.log") == 1 ]]' _ "$tmp"

desc="external display unplugged while the lid is closed: the laptop panel comes back"
reset; setup closed connected; lid closed; reset; setup closed disconnected; lid reconcile
check bash -c 'grep -q "hyprctl reload" "$1/calls.log" && ! grep -q "disabled = true" "$1/calls.log"' _ "$tmp"

desc="lid open with an external display: nothing to do"
reset; setup open connected; lid reconcile
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="a machine without a lid: reconcile does nothing"
reset; rm -rf "$tmp/proc/LID0"; lid reconcile
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="an unknown argument is refused"
status=0; lid frobnicate 2>/dev/null || status=$?
check test "$status" = 2

desc="the Hyprland config binds the lid switch both ways and the monitor events, in the real session only"
check bash -c 'grep -q "switch:on:Lid Switch" "$1" && grep -q "switch:off:Lid Switch" "$1" && grep -q "monitor.added" "$1" && grep -q "monitor.removed" "$1" && grep -q "grassfield.system" "$2" && ! grep -q "grassfield.system" "$3"' _ \
  "$root/config/hypr/grassfield/system.lua" "$root/config/hypr/session.lua" "$root/config/hypr/dev.lua"

exit $fail
