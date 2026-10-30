#!/usr/bin/env bash
# A packaged user unit that restarts itself must be able to reach its start limit: systemd's default (5 starts in 10 s) is never
# reached when RestartSec x 5 exceeds 10 s, so a unit that keeps failing would restart for ever. Every Restart= unit sets
# StartLimitIntervalSec and StartLimitBurst so that Burst x RestartSec < Interval, or has a documented back-off (RestartSteps).
# The lifetime model (ADR-0041 step 1a, audit 1.2): a start limit counts starts, not failures, so a process that lives L seconds
# per cycle makes its (Burst + 1)-th start, the refused one, Burst x (RestartSec + L) after the first. A loop of one crash
# every 10 s (the shell's of 2026-10-29 crashed 5 s after every start) must end: either Burst x (RestartSec + 10) <= Interval,
# or the unit names a failure counter in OnFailure= (grassfield-shell-failed.service, which stops a loop of any pace). The
# shell's first unit (10 in 30 s) fails this model, which is the finding; a negative control below keeps the model honest.
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
  desc="$name ends a loop of one crash every 10 s: the start limit trips for that lifetime, or OnFailure= names the failure counter"
  check python3 -I "$root/tests/shell/unit_restart_limits.py" "$unit"
done
# The lifetime model itself: the shell's first unit (10 starts in 30 s, RestartSec=1, no counter) must fail it, the unit with the
# counter must pass it, and a unit whose limit fits a 10 s lifetime passes without a counter.
model=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/unit-limits.XXXXXX")
trap 'rm -rf "$model"' EXIT
printf '[Unit]\nStartLimitIntervalSec=30\nStartLimitBurst=10\nOnFailure=omarchy-sleep-lock.service\n[Service]\nRestart=always\nRestartSec=1\n' >"$model/first.service"
printf '[Unit]\nStartLimitIntervalSec=30\nStartLimitBurst=10\nOnFailure=omarchy-sleep-lock.service grassfield-shell-failed.service\n[Service]\nRestart=always\nRestartSec=1\n' >"$model/counter.service"
printf '[Unit]\nStartLimitIntervalSec=120\nStartLimitBurst=5\n[Service]\nRestart=on-failure\nRestartSec=5\n' >"$model/fits.service"
desc="the lifetime model rejects the shell's first unit (10 in 30 s: a 10 s loop never trips it, no counter)"
check bash -c '! python3 -I "$1" "$2"' _ "$root/tests/shell/unit_restart_limits.py" "$model/first.service"
desc="the lifetime model accepts the same unit once OnFailure= names the failure counter"
check python3 -I "$root/tests/shell/unit_restart_limits.py" "$model/counter.service"
desc="the lifetime model accepts a limit a 10 s loop reaches (5 x (5 + 10) = 75 <= 120)"
check python3 -I "$root/tests/shell/unit_restart_limits.py" "$model/fits.service"
desc="the scan found the restarting units (shell, crash-watch, battery-watch, automount, menu-bridge)"
check test "$n" -ge 5
exit "$fail"
