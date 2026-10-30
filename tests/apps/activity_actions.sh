#!/usr/bin/env bash
# A-W2 (docs/specs/activity.md "Acceptance criteria"; ADR-0038 step 2c, AM50 to AM56): Activity Monitor's window with its
# real backend on this machine's /proc, offscreen, acting on the test's own children only (each idle, killed and reaped
# when its case ends): the Stop button's sheet and Quit send SIGTERM, Force Quit SIGKILL, a process that ends while the
# sheet is open is silent, a session process gets the warning sheet first and no Stop in Send Signal's pop-up, and in a dev
# session the guard refuses a process outside GRASSFIELD_ACTIVITY_DEV_ROOTS. The cases set GRASSFIELD_DEV and the roots
# themselves, and give the children the unit each case needs (a test's children are in whatever unit runs it).
#
# Usage: tests/apps/activity_actions.sh   Prints the cases; exit 0 passed, 1 failed, 2 refused (run as root: the app runs as
# the user, and root may signal any process).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2
[[ $(id -u) != 0 ]] || { echo "refused: run as the app's user, not root"; exit 2; }
apps/activity/build-direct.sh --tests >/dev/null || { echo "FAIL: building activity-window-qml-tests"; exit 1; }
env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 300 \
  .dev/build/activity-window-qml-tests --gtest_filter='ActivityActions.*' --gtest_brief=1
status=$?
((status == 0)) && echo "PASS: A-W2" || echo "FAIL: A-W2 (exit $status)"
exit $((status == 0 ? 0 : 1))
