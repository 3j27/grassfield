#!/usr/bin/env bash
# Offline test of the gate tooling (scripts/gates/, GF-008): the measurements are checked on processes and files whose
# answer is known. No compositor, no session. Needs gcc/gcov, python3, awk.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=../../scripts/gates/lib.sh
. "$root/scripts/gates/lib.sh"
work=$(mktemp -d)
bg=()
cleanup() { for p in "${bg[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() { # <name> <got> <want>
  if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

python3 -I "$root/scripts/gates/frame_pacing.py" --selftest || fails=$((fails + 1))
python3 -I "$root/scripts/gates/session_start.py" --selftest || fails=$((fails + 1))
"$root/scripts/dev/check-version.sh" --selftest || fails=$((fails + 1))
"$root/scripts/dev/check-licenses.sh" --selftest || fails=$((fails + 1))
"$root/scripts/gates/version-agreement.sh" --selftest || fails=$((fails + 1))

# Release engineering checks on this tree, and the backup recipe on a throwaway folder.
expect "one version source" "$(rc_of "$root/scripts/dev/check-version.sh")" 0
expect "licence notices" "$(rc_of "$root/scripts/dev/check-licenses.sh")" 0
mkdir "$work/bk"
expect "backup writes a verified bundle" "$(rc_of "$root/scripts/dev/backup.sh" "$work/bk")" 0
expect "backup left one bundle and its checksum" "$(find "$work/bk" -type f | wc -l)" 2
expect "backup refuses a folder inside the repository" "$(rc_of "$root/scripts/dev/backup.sh" "$root/docs")" 2

# lib: CPU percent and ticks.
expect "cpu pct" "$(gate_cpu_pct 100 10 100)" "10.000"
expect "ticks readable" "$([[ $(gate_ticks $$) =~ ^[0-9]+$ ]] && echo yes)" yes
expect "rss readable" "$([[ $(gate_rss_kb $$) =~ ^[0-9]+$ ]] && echo yes)" yes

# P1 on a busy and an idle process.
yes >/dev/null &
busy=$!
bg+=("$busy")
sleep 100 &
idle=$!
bg+=("$idle")
out=$("$root/scripts/gates/idle-cpu.sh" --pid "$idle=idle-sleep" --seconds 4 --interval 1 --min-seconds 2 --gate-seconds 1 2>&1)
rc=$?
expect "P1 idle process passes" "$rc" 0
expect "P1 prints the verdict with samples" "$([[ $out == *"P1: PASS"*"4 samples"* ]] && echo yes)" yes
out=$("$root/scripts/gates/idle-cpu.sh" --pid "$busy=busy-yes" --seconds 4 --interval 1 --min-seconds 2 --gate-seconds 1 2>&1)
rc=$?
expect "P1 busy process fails" "$rc" 1
expect "P1 reports the CPU" "$([[ $out == *"P1: FAIL"* ]] && echo yes)" yes
expect "P1 short window is inconclusive" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$idle" --seconds 3 --interval 1 --min-seconds 100)" 2
expect "P1 without a target is an error" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --seconds 3)" 2
expect "P1 short window is a proxy, never a pass" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$idle" --seconds 3 --interval 1 --min-seconds 2)" 2
# The busy process is allowed when the baseline is as busy.
expect "P1 baseline" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$busy" --baseline-pid "$busy" --seconds 3 --interval 1 --min-seconds 2 --gate-seconds 1)" 0

# P2: a process against a baseline.
mb=$(($(gate_rss_kb "$idle") / 1024))
expect "P2 below baseline + delta passes" "$(rc_of "$root/scripts/gates/rss.sh" --pid "$idle" --baseline-mb "$mb")" 0
expect "P2 above baseline + delta fails" "$(rc_of "$root/scripts/gates/rss.sh" --pid "$idle" --baseline-mb 0 --max-delta-mb 0)" 1
expect "P2 without a baseline is inconclusive" "$(rc_of "$root/scripts/gates/rss.sh" --pid "$idle")" 2

# Q3: gcov summary of a program with one uncovered line.
mkdir "$work/cov"
printf 'int f(int x){\n if (x>1)\n  return 1;\n return 0;\n}\nint main(){return f(0);}\n' >"$work/cov/a.c"
if (cd "$work/cov" && gcc --coverage -O0 a.c -o a && ./a); then
  line=$(python3 -I "$root/scripts/gates/coverage_report.py" --label toy --obj-dir "$work/cov" --source-dir "$work/cov")
  expect "coverage of the toy program" "$line" "coverage toy: 80.0 % of 5 lines (4 covered) in 1 files"
  expect "coverage below the minimum fails" "$(rc_of python3 -I "$root/scripts/gates/coverage_report.py" --label toy --obj-dir "$work/cov" --source-dir "$work/cov" --min 90)" 1
  expect "coverage at the minimum passes" "$(rc_of python3 -I "$root/scripts/gates/coverage_report.py" --label toy --obj-dir "$work/cov" --source-dir "$work/cov" --min 80)" 0
  expect "no data is an error" "$(rc_of python3 -I "$root/scripts/gates/coverage_report.py" --label none --obj-dir "$work" --source-dir "$work/none")" 2
else
  echo "  SKIP coverage (gcc --coverage unavailable)"
fi

# P5 from a saved journal.
printf '%s\n' \
  '2026-10-23T00:30:54.619011+02:00 h uwsm[898]: Starting hyprland.desktop and waiting while it is running...' \
  '2026-10-23T00:30:55.869011+02:00 h qs[2000]: INFO qml: grassfield-shell: usable (menu bar and Dock drawn on 1 output(s))' >"$work/j.txt"
expect "P5 fast session passes" "$(rc_of "$root/scripts/gates/session-start.sh" --file "$work/j.txt")" 0
expect "P5 bound too tight fails" "$(rc_of "$root/scripts/gates/session-start.sh" --file "$work/j.txt" --max-s 1.0)" 1

if ((fails == 0)); then echo "PASS gates"; else echo "FAIL gates: $fails"; exit 1; fi
