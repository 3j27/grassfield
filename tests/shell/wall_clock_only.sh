#!/usr/bin/env bash
# No shell or UI file uses Quickshell's SystemClock (static, L0). In 0.3.1 it computes its next tick from local time and
# restarts a 1 ms timer about 800 times a second during the repeated hour of a daylight saving fall-back (2026-10-25);
# every clock goes through shell/services/WallClock.qml, whose ticks come from epoch milliseconds.
# Expected: "wall_clock_only: PASS". Exit 0 PASS, 1 FAIL.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
hits=$(git -C "$root" grep -nE '^[[:space:]]*SystemClock[[:space:]]*\{|SystemClock\.(Seconds|Minutes|Hours)' -- shell ui ':(exclude)shell/services/WallClock.qml')
if [[ -n $hits ]]; then
  echo "FAIL: SystemClock is used; use WallClock (shell/services/WallClock.qml):"
  echo "$hits"
  exit 1
fi
echo "wall_clock_only: PASS"
