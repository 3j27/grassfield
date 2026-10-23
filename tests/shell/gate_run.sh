#!/usr/bin/env bash
# GF-036: scripts/dev/gate-run.sh writes a dated report for every gate run (commit, build id, exit code, log path), keeps the
# command's exit code, never hides SKIP / NOT VERIFIED lines, and `--archive` copies the reports into the repository tree.
# Everything happens in a scratch directory (GATE_RUNS_DIR, GATE_ARCHIVE_DIR).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/gate-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
gr=$root/scripts/dev/gate-run.sh
export GATE_RUNS_DIR=$tmp/runs GATE_ARCHIVE_DIR=$tmp/archive

printf '#!/usr/bin/env bash\necho "PASS: one"\necho "PASS: two"\necho "SKIP: nested session needed"\nexit "${1:-0}"\n' >"$tmp/gate.sh"
chmod +x "$tmp/gate.sh"

rc=0
GATE_STAMP=20261023T120000Z bash "$gr" demo-pass -- "$tmp/gate.sh" 0 >"$tmp/out.txt" 2>"$tmp/err.txt" || rc=$?
report=$tmp/runs/20261023T120000Z-demo-pass.md
desc="a passing command: exit 0, a report and a log named after the stamp and the gate"
check test "$rc" = 0 -a -f "$report" -a -f "$tmp/runs/20261023T120000Z-demo-pass.log"
desc="the command's output still reaches the caller"
check grep -qx "PASS: one" "$tmp/out.txt"
desc="the report has the result, the exit code, the commit, the build id and the log path"
check bash -c 'grep -qx -- "- result: PASS" "$1" && grep -qx -- "- exit code: 0" "$1" && grep -qE -- "^- commit: [0-9a-f]{12} \((clean|dirty)\) on " "$1" && grep -q -- "^- build id: " "$1" && grep -qx -- "- log: $2/runs/20261023T120000Z-demo-pass.log" "$1"' _ "$report" "$tmp"
desc="the report counts PASS and SKIP lines and warns that a run with SKIP lines is not a plain pass"
check bash -c 'grep -qx -- "- lines: PASS 2, FAIL 0, SKIP 1, NOT VERIFIED 0, PROXY 0" "$1" && grep -q -- "^- note: this run is not a plain pass" "$1"' _ "$report"
desc="the log hash in the report is the log's sha256"
check bash -c '[ "$(sed -n "s/^- log sha256: //p" "$1")" = "$(sha256sum "$2" | cut -d" " -f1)" ]' _ "$report" "$tmp/runs/20261023T120000Z-demo-pass.log"

rc=0
GATE_STAMP=20261023T120100Z bash "$gr" demo-fail -- "$tmp/gate.sh" 3 >/dev/null 2>&1 || rc=$?
desc="a failing command: its exit code is kept (3) and the report says FAIL with exit code 3"
check bash -c '[ "$1" = 3 ] && grep -qx -- "- result: FAIL" "$2" && grep -qx -- "- exit code: 3" "$2"' _ "$rc" "$tmp/runs/20261023T120100Z-demo-fail.md"

rc=0
bash "$gr" "Bad Name" -- true >/dev/null 2>&1 || rc=$?
desc="a gate name outside a-z 0-9 . _ - is refused (it becomes a file name)"
check test "$rc" = 2
rc=0
bash "$gr" demo-x true >/dev/null 2>&1 || rc=$?
desc="the command must follow --"
check test "$rc" = 2

printf 'summary: ok\n' >"$tmp/late.log"
GATE_STAMP=20261023T120200Z bash "$gr" --record nested-demo 0 "$tmp/late.log" 2>/dev/null
desc="--record writes the report of a run that happened elsewhere (the nested scripts' summary line)"
check bash -c 'grep -qx -- "- gate: nested-demo" "$1" && grep -qx -- "- log: $2" "$1"' _ "$tmp/runs/20261023T120200Z-nested-demo.md" "$tmp/late.log"
rc=0
bash "$gr" --record nested-demo x "$tmp/late.log" >/dev/null 2>&1 || rc=$?
desc="--record refuses a non-numeric exit code"
check test "$rc" = 2

bash "$gr" --archive 2>/dev/null
desc="--archive copies every report and its log into the archive directory"
check test "$(ls "$tmp/archive"/*.md | wc -l)" = 3 -a -f "$tmp/archive/20261023T120000Z-demo-pass.log"

# A log over 256 KiB is archived as its tail with a note.
head -c 400000 /dev/zero | tr '\0' 'x' | fold -w 80 >"$tmp/big.log"
GATE_STAMP=20261023T120300Z bash "$gr" --record big 0 "$tmp/big.log" 2>/dev/null
rm -rf "$tmp/archive"
bash "$gr" --archive 2>/dev/null
desc="a log over 256 KiB is archived as its last 2000 lines plus a note"
check bash -c '[ "$(wc -l <"$1")" = 2001 ] && tail -n 1 "$1" | grep -q "last 2000 lines only"' _ "$tmp/archive/20261023T120300Z-big.log"
exit "$fail"
