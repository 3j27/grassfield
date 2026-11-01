#!/usr/bin/env bash
# A-E (docs/specs/activity.md "Acceptance criteria"; ADR-0038 AD54, AM68): Efficiency Mode against the user's own systemd
# manager, on a throwaway unit made for the test and stopped at its end. It starts `sleep` in a scope named as uwsm names a
# launch (app-grassfield-activitytest-<8 hex>.scope under app-graphical.slice), then the case `EfficiencyLive.*` turns
# Efficiency Mode on through the app's own code (org.freedesktop.systemd1.Manager.SetUnitProperties on the session bus,
# runtime only) and reads the unit's cgroup (cpu.idle 1, or cpu.weight 1 on a systemd without the idle weight), then off
# (the weight unset). It prints whether systemd enables the cpu controller in app.slice and app-graphical.slice and whether
# it turns it off again once the unit is gone (ADR-0038 g, AM68's side effect). It changes nothing else: no root, no
# setting, no other unit; the scope is the test's.
#
# L2: it needs the user's systemd manager (a real session); a container or a session without one is refused.
# Usage: tests/apps/activity_efficiency.sh   Exit 0 passed, 1 failed, 2 refused (root), 77 skipped (no user manager).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2
[[ $(id -u) != 0 ]] || { echo "refused: run as your own user (Efficiency Mode acts on the user's units only)"; exit 2; }
if ! command -v systemd-run >/dev/null || ! busctl --user status org.freedesktop.systemd1 >/dev/null 2>&1; then
  echo "SKIP: no systemd user manager on the session bus (A-E needs a real session)"
  exit 77
fi
apps/activity/build-direct.sh --tests >/dev/null || { echo "FAIL: building activity-window-tests"; exit 1; }

uid=$(id -u)
slices=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/app.slice
controllers() { echo "app.slice subtree [$(cat "$slices/cgroup.subtree_control" 2>/dev/null)], app-graphical.slice subtree [$(cat "$slices/app-graphical.slice/cgroup.subtree_control" 2>/dev/null)]"; }
echo "before: $(controllers)"

unit="app-grassfield-activitytest-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n').scope"
systemd-run --user --quiet --scope --slice=app-graphical.slice --unit="$unit" sleep 120 &
runner=$!
# A scope has no main pid: its process is the one its cgroup holds.
pid=
for _ in $(seq 50); do
  cg=$(systemctl --user show -p ControlGroup --value "$unit" 2>/dev/null)
  [[ -n $cg ]] && pid=$(head -1 "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null)
  [[ -n $pid ]] && break
  sleep 0.1
done
cleanup() {
  systemctl --user stop "$unit" >/dev/null 2>&1
  kill "$runner" 2>/dev/null
  wait "$runner" 2>/dev/null
}
trap cleanup EXIT
[[ -n $pid ]] || { echo "FAIL: the test scope $unit did not start"; exit 1; }

env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen GRASSFIELD_ACTIVITY_LIVE_PID="$pid" timeout 120 \
  .dev/build/activity-window-tests --gtest_filter='EfficiencyLive.*' --gtest_brief=1
status=$?
echo "with the unit set and unset: $(controllers)"
cleanup
trap - EXIT
sleep 1
echo "after the unit ended: $(controllers)"
((status == 0)) && echo "PASS: A-E" || echo "FAIL: A-E (exit $status)"
exit $((status == 0 ? 0 : 1))
