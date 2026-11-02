#!/usr/bin/env bash
# ADR-0041 step 6a (owner decision SQ-5 A): packaging/bin/grassfield-shell-watchdog, the shell's liveness probe, against
# stubs: `qs` answers, hangs or fails as the case wants, `systemctl` reports the shell unit's state from a file and logs every
# call, a session-gone stand-in answers what the case wants. Both commands are fakes first on a private PATH: no session, no
# systemd, no Quickshell, nothing real is asked or killed.
#   - an answer (`refused` included) is the shell alive: nothing counted, nothing killed;
#   - three questions in a row that run into the 5 s bound kill the shell's main process with SIGKILL, once, and nothing
#     else; an answer in between starts again from zero;
#   - a question that fails at once, a unit that is not active/running, a shell that restarted between two misses or during
#     the question, a session that ends: nothing counted, nothing killed;
#   - the state is the user's own file (0600 in a 0700 directory), never written through a link.
# About 45 s: each miss waits out the real 5 s bound.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-watchdog.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/run"
cp "$root/packaging/bin/grassfield-shell-watchdog" "$tmp/lib/grassfield-shell-watchdog"
cat >"$tmp/lib/session-gone" <<'SH'
#!/bin/sh
[ "${FAKE_GONE:-0}" = 1 ] && exit 0
exit 1
SH
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_LOG"
[ "$*" = "--user show -p ActiveState -p SubState -p MainPID grassfield-shell.service" ] && cat "$FAKE_UNIT"
exit 0
SH
# `exec sleep`: the sleep is the process timeout signals, so no stray sleep outlives a case.
cat >"$tmp/bin/qs" <<'SH'
#!/bin/sh
echo "qs $*" >>"$FAKE_LOG"
case $(cat "$FAKE_QS") in
  answer) echo refused ;;
  hang) exec sleep 30 ;;
  restart) printf 'ActiveState=active\nSubState=running\nMainPID=4242\n' >"$FAKE_UNIT"; exec sleep 30 ;;
  fail) echo "No running instances"; exit 1 ;;
  slowfail) sleep 4.7; echo "connection reset"; exit 1 ;;
  killed) kill -9 $$ ;;
esac
exit 0
SH
chmod +x "$tmp/lib/grassfield-shell-watchdog" "$tmp/lib/session-gone" "$tmp/bin/systemctl" "$tmp/bin/qs"
state=$tmp/run/grassfield/shell-watchdog
unit() { printf 'ActiveState=%s\nSubState=%s\nMainPID=%s\n' "$1" "$2" "$3" >"$tmp/unit"; }
qs_does() { echo "$1" >"$tmp/qs"; }
run() { # [VAR=value...]: the probe once; its exit code in $rc
  rc=0
  env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 FAKE_LOG="$tmp/log" \
    FAKE_UNIT="$tmp/unit" FAKE_QS="$tmp/qs" "$@" sh "$tmp/lib/grassfield-shell-watchdog" 2>>"$tmp/err" || rc=$?
  return 0
}
kill_line="systemctl --user kill --kill-whom=main --signal=SIGKILL grassfield-shell.service"
kills() { grep -c -x -- "$kill_line" "$tmp/log" 2>/dev/null || true; }
asked() { grep -c "^qs " "$tmp/log" 2>/dev/null || true; }
saved() { cat "$state" 2>/dev/null || echo none; }
fresh() { rm -rf "$tmp/run/grassfield" "$tmp/log" "$tmp/err"; : >"$tmp/log"; unit active running 1234; }

# 1. Alive.
fresh; qs_does answer; run
desc="an answer (refused, as in a real session) is the shell alive: exit 0, nothing kept, nothing killed"
check test "$rc" = 0 -a "$(saved)" = none -a "$(kills)" = 0
desc="the question names the shell by its system path and asks capabilities status, nothing else"
check grep -qx "qs ipc -p /usr/share/grassfield/shell call capabilities status" "$tmp/log"
fresh; qs_does answer; run WAYLAND_DISPLAY=
desc="without WAYLAND_DISPLAY (the user manager's environment) the question lifts the display filter (--any-display)"
check grep -qx "qs ipc --any-display -p /usr/share/grassfield/shell call capabilities status" "$tmp/log"

# 2. Misses: two kept, an answer forgets them, then three in a row kill once.
fresh; qs_does hang; run
desc="a question that runs into the 5 s bound is one miss of that process (state \"1234 1\"), nothing killed"
check test "$rc" = 0 -a "$(saved)" = "1234 1" -a "$(kills)" = 0
run
desc="a second miss in a row: \"1234 2\", nothing killed"
check test "$(saved)" = "1234 2" -a "$(kills)" = 0
desc="the state is the user's own file: 0600 in a 0700 directory"
check test "$(stat -c %a "$state")" = 600 -a "$(stat -c %a "$tmp/run/grassfield")" = 700
qs_does answer; run
desc="an answer after two misses starts again from zero (the state is gone)"
check test "$(saved)" = none -a "$(kills)" = 0
qs_does hang; run; run
desc="two new misses: \"1234 2\", still nothing killed"
check test "$(saved)" = "1234 2" -a "$(kills)" = 0
run
desc="the third miss in a row kills the shell's main process with SIGKILL through the user manager, once, and forgets the misses"
check test "$rc" = 0 -a "$(kills)" = 1 -a "$(saved)" = none
desc="it runs nothing else: systemctl only to read the unit's state and for that one kill (no stop, restart, start or reset)"
check test "$(grep "^systemctl " "$tmp/log" | grep -v -x -c -e "$kill_line" -e "systemctl --user show -p ActiveState -p SubState -p MainPID grassfield-shell.service")" = 0

# 3. What is never counted.
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1111 2" >"$state"; qs_does hang; run
desc="misses of another process (a shell that restarted between two questions) are forgotten: \"1234 1\", nothing killed"
check test "$(saved)" = "1234 1" -a "$(kills)" = 0
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$state"; qs_does restart; run
desc="a shell that restarted during the question (another MainPID after it) counts nothing and starts from zero"
check test "$(saved)" = none -a "$(kills)" = 0
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$state"; qs_does fail; run
desc="a question that fails at once (no instance) is no evidence of a hang: the misses stay as they were, nothing killed"
check test "$(saved)" = "1234 2" -a "$(kills)" = 0
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$state"; qs_does slowfail; run
desc="a question that fails just under the bound (exit 1 after 4.7 s) is not a timeout: nothing counted, nothing killed"
check test "$(saved)" = "1234 2" -a "$(kills)" = 0
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$state"; qs_does killed; run
desc="a qs killed at once (exit 137 before the bound, as the unit's memory limit would) is not a miss: nothing counted, nothing killed"
check test "$(saved)" = "1234 2" -a "$(kills)" = 0
for st in "activating start 0" "failed failed 0" "active running 0" "active exited 1234"; do
  fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$state"; qs_does hang
  # shellcheck disable=SC2086
  unit $st; run
  desc="a unit that is not running a main process ($st): nothing asked, the misses forgotten, nothing killed"
  check test "$(asked)" = 0 -a "$(saved)" = none -a "$(kills)" = 0
done
fresh; qs_does hang; run FAKE_GONE=1
desc="once the compositor is gone (the session ends): nothing read, nothing asked"
check test "$rc" = 0 -a ! -s "$tmp/log"
fresh; qs_does hang; run XDG_RUNTIME_DIR=
desc="without XDG_RUNTIME_DIR nothing is asked or killed"
check test "$rc" = 0 -a "$(asked)" = 0 -a "$(kills)" = 0
fresh; mkdir -p -m 700 "$tmp/run/grassfield"; echo "1234 2" >"$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$state"; qs_does hang; run
desc="a link at the state's path is neither read nor written through: the miss counts as the first, the linked file is untouched"
check test "$(cat "$tmp/elsewhere")" = "1234 2" -a ! -L "$state" -a "$(saved)" = "1234 1" -a "$(kills)" = 0

# 4. The helper itself.
h=$root/packaging/bin/grassfield-shell-watchdog
desc="the helper clears Quickshell's option variables, waits 5 s per question, kills at the third miss, and never stops, restarts, starts or unlocks"
check bash -c 'grep -qx "unset QS_CONFIG_PATH QS_CONFIG_NAME QS_MANIFEST" "$1" && grep -qx "answer=5" "$1" && grep -qx "misses_max=3" "$1" &&
  ! grep -v "^#" "$1" | grep -qE "systemctl[^#]*(stop|restart|start|reset-failed)|unlock|sudo|pkexec"' _ "$h"
exit $fail
