#!/usr/bin/env bash
# FINDINGS 9: the foreign locker fixture must never be started without a display (Quickshell aborts and dumps core). The
# wrapper tests/security/foreign_locker/run.sh refuses without a Wayland socket, and every script that launches the fixture
# goes through it. Nothing here starts qs.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
run=$root/tests/security/foreign_locker/run.sh
desc="the wrapper exits 2 without WAYLAND_DISPLAY"
status=0; env -i PATH="$PATH" "$run" >/dev/null 2>&1 || status=$?
check test "$status" = 2
desc="the wrapper exits 2 when the socket does not exist"
status=0; env -i PATH="$PATH" WAYLAND_DISPLAY=nonexistent-socket XDG_RUNTIME_DIR=/nonexistent "$run" >/dev/null 2>&1 || status=$?
check test "$status" = 2
desc="no script starts the fixture with a bare qs -p (only through the wrapper)"
check bash -c '! grep -rn "qs -p \"\$foreign\"" "$1/tests" --include=*.sh' _ "$root"
exit "$fail"
