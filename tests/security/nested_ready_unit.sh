#!/usr/bin/env bash
# Offline checks of tests/security/nested_ready.sh, the readiness wait of the nested security scenarios (reload_locked.sh,
# lock_privacy.sh): an empty or unknown `lock status` answer is "not ready", never a lock state; a timeout fails with a
# reason; nothing proceeds on an unknown state. hyprctl and qs are stubs on PATH (a scratch directory): nothing here talks
# to a compositor or a shell, and nothing is started but the stubs.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/nested-ready.XXXXXX") || { echo "FAIL: no scratch directory"; exit 1; }
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
# hyprctl stub: prints $scratch/monitors.json for `-j monitors`.
cat >"$scratch/bin/hyprctl" <<EOF
#!/usr/bin/env bash
[[ \$* == "-j monitors" ]] && cat "$scratch/monitors.json"
EOF
# qs stub: answers `ipc -p <dir> call lock status` with the next line of $scratch/answers (the last line repeats), counting
# calls in $scratch/calls. An empty line is the answer of a shell whose IPC is not up yet (nothing on stdout).
cat >"$scratch/bin/qs" <<EOF
#!/usr/bin/env bash
[[ \$1 == ipc && \$4 == call && \$5 == lock && \$6 == status ]] || exit 3
n=\$((\$(cat "$scratch/calls" 2>/dev/null || echo 0) + 1))
echo "\$n" >"$scratch/calls"
total=\$(wc -l <"$scratch/answers")
line=\$(sed -n "\$((n < total ? n : total))p" "$scratch/answers")
[[ -n \$line ]] && printf '%s\n' "\$line"
exit 0
EOF
chmod +x "$scratch/bin/hyprctl" "$scratch/bin/qs"
export PATH="$scratch/bin:$PATH"

# shellcheck source=nested_ready.sh
. "$root/tests/security/nested_ready.sh"

gfref='[{"name":"WAYLAND-1"},{"name":"GF-REF"}]'
scenario() { # <monitors json> <answers, one per line>: resets the stubs
  printf '%s\n' "$1" >"$scratch/monitors.json"
  printf '%s\n' "$2" >"$scratch/answers"
  rm -f "$scratch/calls"
}
run() { # <seconds>: sets rc
  rc=0
  nested_ready test-sig test-sock /nonexistent/shell "$1" || rc=$?
}

scenario "$gfref" ""
run 1
desc="a shell that never answers is not ready: timeout, exit 1, no state, a reason naming lock status"
check test "$rc:$nested_ready_state" = "1:"
desc="the timeout reason names the missing lock state"
check grep -q "did not answer \`lock status\` with a lock state" <<<"$nested_ready_why"

scenario "$gfref" "Error: no running instance"
run 1
desc="an unknown answer is not a lock state (exit 1)"
check test "$rc:$nested_ready_state" = "1:"

scenario '[{"name":"WAYLAND-1"}]' "unlocked"
run 1
desc="without GF-REF nothing is ready even when the shell answers (exit 1, reason names GF-REF)"
check test "$rc:$nested_ready_state" = "1:"
desc="the shell is not asked before GF-REF is listed"
check test ! -e "$scratch/calls"
desc="the timeout reason names GF-REF"
check grep -q "GF-REF" <<<"$nested_ready_why"

scenario "$gfref" $'\n\n\nunlocked'
run 5
desc="empty answers are waited out: ready on the first lock state (unlocked), after 4 calls"
check test "$rc:$nested_ready_state:$(cat "$scratch/calls")" = "0:unlocked:4"
desc="the time waited is reported in ms"
check grep -Eq '^[0-9]+$' <<<"$nested_ready_ms"

scenario "$gfref" $'\nlocked'
run 5
desc="a locked session is reported locked, never unlocked"
check test "$rc:$nested_ready_state" = "0:locked"

for state in locking authenticating releasing; do
  scenario "$gfref" "$state"
  run 2
  desc="the lock state $state is a known state"
  check test "$rc:$nested_ready_state" = "0:$state"
done

scenario "$gfref" "refused"
run 5
desc="a shell that refuses the dev hooks stops the wait at once (exit 2, no state)"
check test "$rc:$nested_ready_state:$(cat "$scratch/calls")" = "2::1"

scenario "$gfref" "unlocked"
run abc
desc="a malformed timeout fails (exit 1)"
check test "$rc:$nested_ready_state" = "1:"
desc="a malformed timeout asks nothing"
check test ! -e "$scratch/calls"

# The scenarios themselves: the readiness wait comes before their step loops, and no step reads a raw first answer as
# the lock state (lock_privacy.sh once stopped on an empty answer as "already locked").
for f in reload_locked.sh lock_privacy.sh; do
  desc="$f sources nested_ready.sh and waits before its step loop"
  check awk '/^\. "\$root\/tests\/security\/nested_ready.sh"/ { s = NR } /nested_ready "\$sig" "\$sock" "\$root\/shell"/ && !w { w = NR }
    /^for s in "\$\{steps\[@\]\}"; do$/ && w { l = NR } END { exit !(s && w && l > w && w > s) }' "$root/tests/security/$f"
done
desc="lock_privacy.sh decides 'already locked' on the readiness state, not on a raw ipc answer"
check bash -c '! grep -q "\[\[ \$(ipc lock status) == unlocked" "$1" && grep -q "nested_ready_state == unlocked" "$1"' _ "$root/tests/security/lock_privacy.sh"
desc="reload_locked.sh waits for the restarted shell to answer before its status checks (no bare wait after shell-run.sh)"
check bash -c '! grep -A1 "scripts/dev/shell-run.sh\"$" "$1" | grep -q "wait_status locked"' _ "$root/tests/security/reload_locked.sh"
exit "$fail"
