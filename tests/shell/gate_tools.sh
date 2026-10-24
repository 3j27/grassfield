#!/usr/bin/env bash
# GF-008 residual tools: scripts/gates/p4-search-latency.sh and scripts/gates/r1-restart.sh give honest verdicts. Fixtures only:
# a small file tree, journal excerpts and shell logs written here; the real journal and sessions are never read.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/gate-tools.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
p4=$root/scripts/gates/p4-search-latency.sh
r1=$root/scripts/gates/r1-restart.sh

# ---- P4 ----
if command -v plocate >/dev/null && command -v updatedb >/dev/null; then
  out=$(P4_FIXTURE_DIR=$tmp/fx bash "$p4" --files 1000 --runs 2 2>&1) && rc=0 || rc=$?
  desc="P4 on a fixture: the provider alone is PROXY (never PASS), the fixture is removed afterwards"
  check bash -c 'grep -q "^P4 files: PROXY plocate on 1000 files" <<<"$1" && grep -q "excludes the shell" <<<"$1" && [[ $2 == 0 && ! -e "$3/fx" ]]' _ "$out" "$rc" "$tmp"
  out=$(P4_FIXTURE_DIR=$tmp/fx bash "$p4" --files 1000 --runs 1 --limit-ms 0 2>&1) && rc=0 || rc=$?
  desc="P4: a provider slower than the limit FAILS (a lower bound over the limit is conclusive)"
  check bash -c 'grep -q "^P4 files: FAIL" <<<"$1" && [[ $2 == 1 ]]' _ "$out" "$rc"
else
  echo "SKIP: plocate/updatedb not installed"
fi
printf 'x search keystroke->results 12 ms, 3 results\nx search keystroke->results 31 ms, 3 results\n' >"$tmp/apps-ok.log"
printf 'x search keystroke->results 80 ms, 3 results\n' >"$tmp/apps-slow.log"
printf 'x search files via plocate 120 results, merge 40 ms\n' >"$tmp/files.log"
out=$(bash "$p4" --files 0 --shell-log-apps "$tmp/apps-ok.log" 2>&1) && rc=0 || rc=$?
desc="P4: app results from the shell's own timestamps within 50 ms: PASS"
check bash -c 'grep -q "^P4 app results per keystroke (shell): PASS" <<<"$1" && [[ $2 == 0 ]]' _ "$out" "$rc"
out=$(bash "$p4" --files 0 --shell-log-apps "$tmp/apps-slow.log" 2>&1) && rc=0 || rc=$?
desc="P4: app results over 50 ms: FAIL, exit 1"
check bash -c 'grep -q "^P4 app results per keystroke (shell): FAIL" <<<"$1" && [[ $2 == 1 ]]' _ "$out" "$rc"
out=$(bash "$p4" --files 0 --shell-log-files "$tmp/files.log" 2>&1) && rc=0 || rc=$?
desc="P4: the shell logs only the merge of file results: PROXY, not PASS"
check bash -c 'grep -q "^P4 file results (shell): PROXY" <<<"$1" && grep -q "lower bound" <<<"$1"' _ "$out"
out=$(bash "$p4" --files 0 2>&1) && rc=0 || rc=$?
desc="P4: nothing to measure is NOT VERIFIED"
check grep -q "^P4 all: NOT VERIFIED" <<<"$out"
out=$(bash "$p4" --files 0 --shell-log-apps "$tmp/missing.log" 2>&1) && rc=0 || rc=$?
desc="P4: an unreadable log is NOT VERIFIED"
check grep -q "NOT VERIFIED (log .* not readable)" <<<"$out"

# ---- R1 ----
j() { printf '%s systemd[1]: %s\n' "$1" "$2"; }
q() { printf '%s qs[9]:   INFO qml: grassfield-shell: started, plugin protocol gfc/1 lock %s\n' "$1" "$2"; }
{
  j 2026-10-23T10:00:00.000000+02:00 "Started Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  q 2026-10-23T10:00:01.000000+02:00 unlocked
  j 2026-10-23T11:00:00.000000+02:00 "grassfield-shell.service: Main process exited, code=killed, status=11/SEGV"
  j 2026-10-23T11:00:01.000000+02:00 "grassfield-shell.service: Scheduled restart job, restart counter is at 1."
  j 2026-10-23T11:00:01.200000+02:00 "Started Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  q 2026-10-23T11:00:02.100000+02:00 unlocked
} >"$tmp/j-pass.txt"
sed 's/11:00:02.100000/11:00:08.100000/' "$tmp/j-pass.txt" >"$tmp/j-slow.txt"
sed 's/lock unlocked$/lock locked/; 1,2!b' "$tmp/j-pass.txt" >/dev/null
{
  j 2026-10-23T10:00:00.000000+02:00 "Started Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  q 2026-10-23T10:00:01.000000+02:00 locked
  j 2026-10-23T11:00:00.000000+02:00 "grassfield-shell.service: Main process exited, code=killed, status=11/SEGV"
  j 2026-10-23T11:00:01.000000+02:00 "grassfield-shell.service: Scheduled restart job, restart counter is at 1."
  q 2026-10-23T11:00:02.100000+02:00 unlocked
} >"$tmp/j-lockchange.txt"
{
  j 2026-10-23T10:00:00.000000+02:00 "Started Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  q 2026-10-23T10:00:01.000000+02:00 unlocked
  j 2026-10-23T12:00:00.000000+02:00 "grassfield-shell.service: Main process exited, code=exited, status=255/EXCEPTION"
  j 2026-10-23T12:00:00.100000+02:00 "Stopped Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  j 2026-10-23T12:00:20.000000+02:00 "Started Grassfield shell (menu bar, Dock, notifications, lock, polkit agent)."
  q 2026-10-23T12:00:21.000000+02:00 unlocked
} >"$tmp/j-logout.txt"
r1run() { R1_JOURNAL_FILE=$1 bash "$r1" --journal 2>&1; }
out=$(r1run "$tmp/j-pass.txt") && rc=0 || rc=$?
desc="R1: a restart in 2.1 s with the lock state kept: PASS"
check bash -c 'grep -q "^R1 journal: PASS (1 restart(s), worst 2100 ms" <<<"$1" && [[ $2 == 0 ]]' _ "$out" "$rc"
out=$(r1run "$tmp/j-slow.txt") && rc=0 || rc=$?
desc="R1: a restart in 8.1 s: FAIL, exit 1"
check bash -c 'grep -q "^R1 journal: FAIL (1 restart(s), worst 8100 ms" <<<"$1" && [[ $2 == 1 ]]' _ "$out" "$rc"
out=$(r1run "$tmp/j-lockchange.txt") && rc=0 || rc=$?
desc="R1: a restart that lost the lock state (locked before, unlocked after): FAIL"
check bash -c 'grep -q "^R1 journal: FAIL (.*lock state differed" <<<"$1" && [[ $2 == 1 ]]' _ "$out" "$rc"
out=$(r1run "$tmp/j-logout.txt") && rc=0 || rc=$?
desc="R1: a logout and a later login is not a restart: NOT VERIFIED (no restart of the unit)"
check bash -c 'grep -q "^R1 journal: NOT VERIFIED (no restart" <<<"$1" && [[ $2 == 0 ]]' _ "$out" "$rc"
exit "$fail"
