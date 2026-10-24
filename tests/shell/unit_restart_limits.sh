#!/usr/bin/env bash
# A packaged user unit that restarts itself must be able to reach its start limit: systemd's default (5 starts in 10 s) is never
# reached when RestartSec x 5 exceeds 10 s, so a unit that keeps failing would restart for ever. Every Restart= unit sets
# StartLimitIntervalSec and StartLimitBurst so that Burst x RestartSec < Interval, or has a documented back-off (RestartSteps).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
n=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

for unit in "$root"/packaging/systemd/*.service; do
  name=$(basename "$unit")
  grep -qE '^Restart=(on-failure|always|on-abnormal|on-abort)$' "$unit" || continue
  n=$((n + 1))
  if grep -q '^RestartSteps=' "$unit"; then
    desc="$name restarts with a growing back-off (RestartSteps), by design"
    check true
    continue
  fi
  desc="$name sets a start limit that its RestartSec can reach (Burst x RestartSec < Interval)"
  check python3 -I -c '
import re, sys
t = open(sys.argv[1]).read()
def num(key):
    m = re.search(r"^" + key + r"=(\d+)$", t, re.M)
    return int(m[1]) if m else None
interval, burst, sec = num("StartLimitIntervalSec"), num("StartLimitBurst"), num("RestartSec") or 1
sys.exit(0 if interval and burst and burst * sec < interval else 1)' "$unit"
done
desc="the scan found the restarting units (shell, crash-watch, battery-watch, automount, menu-bridge)"
check test "$n" -ge 5
exit "$fail"
