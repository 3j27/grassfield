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
check bash -c 'grep -qx -- "- result: PASS" "$1" && grep -qx -- "- exit code: 0" "$1" && grep -qE -- "^- commit: [0-9a-f]{12} \((clean|dirty[^)]*)\) on " "$1" && grep -q -- "^- build id: " "$1" && grep -qx -- "- log: $2/runs/20261023T120000Z-demo-pass.log" "$1"' _ "$report" "$tmp"
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

# GF-082: a read-only core dump summary per dump, from a fake coredumpctl (never the host's journal).
cat >"$tmp/coredumpctl" <<'FAKE'
#!/usr/bin/env bash
# fake: list gives two dumps as JSON, info prints coredumpctl-style fields; any other verb is a failure
case " $* " in
  *" list "*) echo '[{"time":1,"pid":4242,"sig":11,"exe":"/usr/bin/quickshell"},{"time":2,"pid":4343,"sig":6,"exe":"/usr/lib/xdg-desktop-portal-hyprland"}]' ;;
  *" info 4242 "*) printf '           PID: 4242 (qs)\n        Signal: 11 (SEGV)\n     Timestamp: Fri 2026-10-23 12:00:00 UTC\n          Unit: grassfield-shell.service\n       Session: 2\n    Executable: /usr/bin/quickshell\n  Command Line: qs -n -p /usr/share/grassfield/shell\n' ;;
  *" info 4343 "*) printf '           PID: 4343\n        Signal: 6 (ABRT)\n    Executable: /usr/lib/xdg-desktop-portal-hyprland\n  Command Line: /usr/lib/xdg-desktop-portal-hyprland\n' ;;
  *) exit 9 ;;
esac
FAKE
chmod +x "$tmp/coredumpctl"
out=$(COREDUMPCTL="$tmp/coredumpctl" python3 -I "$root/scripts/dev/coredump-summary.py" --since today)
desc="coredump-summary: one attributed line per dump (class, pid, signal, executable basename, time; no command line)"
check bash -c 'grep -q "^  GRASSFIELD pid 4242 sig 11 exe quickshell time " <<<"$1" && grep -q "^  OTHER      pid 4343 sig 6 exe xdg-desktop-portal-hyprland" <<<"$1" && grep -q "classes: GRASSFIELD 1, OTHER 1" <<<"$1" && ! grep -q "/usr/share/grassfield\|Command Line\|unit " <<<"$1"' _ "$out"
# GF-082 review M3: a crashed program with a token in its arguments must never reach the report (nor the archive).
cat >"$tmp/coredumpctl-secret" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" list "*) echo '[{"time":1,"pid":777,"sig":11,"exe":"/usr/bin/curl"}]' ;;
  *" info 777 "*) printf '           PID: 777\n        Signal: 11 (SEGV)\n    Executable: /usr/bin/curl\n  Command Line: curl -H Authorization:\\ Bearer\\ abc123SECRET https://api.example.org/?token=abc123SECRET\n   Environment: API_KEY=abc123SECRET\n' ;;
  *) exit 9 ;;
esac
FAKE
chmod +x "$tmp/coredumpctl-secret"
out=$(COREDUMPCTL="$tmp/coredumpctl-secret" python3 -I "$root/scripts/dev/coredump-summary.py")
desc="coredump-summary: the token in a crashed program's arguments or environment never appears in the summary"
check bash -c 'grep -q "pid 777 sig 11 exe curl" <<<"$1" && ! grep -q "abc123SECRET\|Bearer\|token=\|API_KEY" <<<"$1"' _ "$out"
GATE_STAMP=20261023T131000Z COREDUMPCTL="$tmp/coredumpctl-secret" bash "$gr" demo-secret -- true >/dev/null 2>&1
rm -rf "$tmp/archive"
bash "$gr" --archive 2>/dev/null
desc="...nor in the gate report or the archive copied from it"
check bash -c '! grep -rq "abc123SECRET\|Bearer" "$1/runs" "$1/archive"' _ "$tmp"
out=$(COREDUMPCTL="$tmp/does-not-exist" python3 -I "$root/scripts/dev/coredump-summary.py")
desc="coredump-summary: without coredumpctl it says so and exits 0"
check grep -q "^coredumps: unknown (coredumpctl unavailable" <<<"$out"
# GF-082/GF-036 review: no access is "unknown", never "none"; a command that measures nothing is NOT VERIFIED.
printf '#!/bin/sh\necho "Failed to acquire bus: Operation not permitted" >&2\nexit 1\n' >"$tmp/coredumpctl-nobus"
printf '#!/bin/sh\necho "No coredumps found." >&2\nexit 1\n' >"$tmp/coredumpctl-none"
chmod +x "$tmp/coredumpctl-nobus" "$tmp/coredumpctl-none"
out=$(COREDUMPCTL="$tmp/coredumpctl-nobus" python3 -I "$root/scripts/dev/coredump-summary.py")
desc="coredump-summary: no access to the journal or bus is 'unknown (no access)', not 'none'"
check bash -c 'grep -q "^coredumps: unknown (no access to the journal" <<<"$1" && ! grep -q "none" <<<"$1"' _ "$out"
out=$(COREDUMPCTL="$tmp/coredumpctl-none" python3 -I "$root/scripts/dev/coredump-summary.py")
desc="coredump-summary: coredumpctl's own 'No coredumps found' is 'none'"
check grep -q "^coredumps: none since" <<<"$out"
GATE_STAMP=20261023T130500Z bash "$gr" demo-silent -- true >/dev/null 2>&1
desc="a gate command that prints nothing (a silent true) is NOT VERIFIED, not a measured pass"
check grep -q "^- verdict: NOT VERIFIED (exit 0 but the log has no PASS line" "$tmp/runs/20261023T130500Z-demo-silent.md"
printf '#!/bin/sh\necho "PASS: a"\n' >"$tmp/measures.sh"; chmod +x "$tmp/measures.sh"
GATE_STAMP=20261023T130600Z bash "$gr" demo-measured -- "$tmp/measures.sh" >/dev/null 2>&1
desc="a gate command with a PASS line and no caveat is a measured pass"
check grep -q "^- verdict: measured pass" "$tmp/runs/20261023T130600Z-demo-measured.md"
GATE_STAMP=20261023T130000Z COREDUMPCTL="$tmp/coredumpctl" bash "$gr" demo-dump -- true >/dev/null 2>&1
desc="a gate run's report names the dumps made during the run and keeps the details next to the log"
check bash -c 'grep -q -- "^- coredumps: coredumps since .*: 2" "$1" && grep -q "GRASSFIELD pid 4242" "$2"' _ "$tmp/runs/20261023T130000Z-demo-dump.md" "$tmp/runs/20261023T130000Z-demo-dump.coredumps"
# Review: any FAIL line means FAIL even when the exit code is 0; an untracked file makes the tree dirty.
printf '#!/bin/sh\necho "PASS: a"\necho "FAIL: b"\n' >"$tmp/mixed.sh"; chmod +x "$tmp/mixed.sh"
GATE_STAMP=20261023T131500Z bash "$gr" demo-mixed -- "$tmp/mixed.sh" >/dev/null 2>&1
desc="a log with PASS and FAIL lines that exits 0 is a FAIL, not a measured pass"
check grep -q "^- verdict: FAIL (1 FAIL line(s)" "$tmp/runs/20261023T131500Z-demo-mixed.md"
mkdir -p "$tmp/repo/scripts/dev"
cp "$root/scripts/dev/gate-run.sh" "$tmp/repo/scripts/dev/"
cp "$root/scripts/dev/coredump-summary.py" "$tmp/repo/scripts/dev/"
git -C "$tmp/repo" init -q 2>/dev/null
git -C "$tmp/repo" add -A 2>/dev/null
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.org commit -q -m init 2>/dev/null
GATE_RUNS_DIR="$tmp/r2" GATE_STAMP=20261023T131600Z bash "$tmp/repo/scripts/dev/gate-run.sh" demo-clean -- "$tmp/measures.sh" >/dev/null 2>&1
: >"$tmp/repo/stray-file"
GATE_RUNS_DIR="$tmp/r2" GATE_STAMP=20261023T131700Z bash "$tmp/repo/scripts/dev/gate-run.sh" demo-stray -- "$tmp/measures.sh" >/dev/null 2>&1
desc="a clean tree is 'clean'; a tree with only an untracked file is dirty"
check bash -c 'grep -q "^- commit: [0-9a-f]* (clean) on" "$1/r2/20261023T131600Z-demo-clean.md" && grep -q "^- commit: [0-9a-f]* (dirty: " "$1/r2/20261023T131700Z-demo-stray.md"' _ "$tmp"
exit "$fail"
