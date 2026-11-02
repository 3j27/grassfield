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
"$root/scripts/gates/rc-toolkit.sh" --selftest || fails=$((fails + 1))

# The user's compositor rebuild (/usr/src/grassfield-compositor as the package lays it out: no ../cmake, the pacman source id in
# VERSION, the product version in cmake/VERSION) must configure and carry the product version.
if command -v cmake >/dev/null && command -v ninja >/dev/null && pkg-config --exists hyprland; then
  rb=$work/usr-src/grassfield-compositor
  mkdir -p "$rb"
  # The very list the PKGBUILD installs (packaging/arch/compositor-rebuild-sources.txt).
  while read -r from to; do
    [[ -z $from || $from == \#* ]] && continue
    mkdir -p "$(dirname "$rb/$to")"
    cp -r "$root/$from" "$rb/$to"
  done <"$root/packaging/arch/compositor-rebuild-sources.txt"
  echo "1.0.0rc1-1" >"$rb/VERSION"
  expect "the shipped rebuild sources configure" "$(rc_of cmake -S "$rb" -B "$work/usr-src/build" -G Ninja -DGRASSFIELD_BUILD_TESTS=OFF)" 0
  expect "and compile the product version in" "$(grep -c "GRASSFIELD_VERSION=.*$(tr -d '[:space:]' <"$root/VERSION")" "$work/usr-src/build/build.ninja" | awk '$1 > 0 {print "yes"}')" yes
else
  echo "  SKIP the shipped rebuild layout (cmake, ninja or the hyprland headers missing)"
fi

# The environmental-line filter of global_menus.sh on lines in the real shell.log format (timestamp, two spaces, level).
. "$root/tests/integration/env_lines.sh"
real_pam='2026-10-23 03:35:20.400  WARN qml: grassfield-lock: dev: PAM is suppressed on the lock (no real authentication; set GRASSFIELD_DEV_ALLOW_PAM=1 for the L2 failure-path test)'
qs_polkit='2026-10-23 03:35:21.100 ERROR quickshell.service.polkit: failed to register listener: Operation not permitted'
elsewhere='2026-10-23 03:35:22.000  WARN qml: boom ERROR quickshell.service.polkit: failed to register listener: in the middle'
other_lock='2026-10-23 03:35:23.000  WARN qml: grassfield-lock: dev: PAM is suppressed on the lock (and another thing)'
real_issue='2026-10-23 03:35:24.000  WARN qml: TypeError: Cannot read property x of null'
left=$(printf '%s\n' "$real_pam" "$qs_polkit" "$elsewhere" "$other_lock" "$real_issue" | filter_env_lines)
expect "the real PAM line is environmental" "$([[ $left != *"PAM is suppressed on the lock (no real"* ]] && echo yes)" yes
expect "Quickshell's polkit line, with its timestamp, is environmental" "$([[ $left != *"Operation not permitted"* ]] && echo yes)" yes
expect "the same text in the middle of another line stays visible" "$([[ $left == *"in the middle"* ]] && echo yes)" yes
expect "a longer lock message stays visible" "$([[ $left == *"and another thing"* ]] && echo yes)" yes
expect "a real issue stays visible" "$([[ $left == *"TypeError"* ]] && echo yes)" yes
expect "exactly three lines are left" "$(wc -l <<<"$left")" 3

# PKGBUILD prepare(): a rerun for another commit starts from nothing (stale build directories answered "no work to do").
pk=$work/pkg
mkdir -p "$pk/src/compositor-build" "$pk/src/compositor-out" "$pk/src/files-build" "$pk/src/snapshot"
echo stale >"$pk/src/compositor-build/stale" && echo stale >"$pk/src/compositor-out/libgfcore.a" && echo stale >"$pk/src/files-build/x" && echo old >"$pk/src/snapshot/old"
started=$(date +%s)
sleep 1
(
  startdir=$root/packaging/arch srcdir=$pk/src
  # shellcheck source=/dev/null
  . "$root/packaging/arch/PKGBUILD"
  prepare >/dev/null 2>&1
)
expect "prepare removes the build and output directories of an earlier run" "$([[ ! -e $pk/src/compositor-build && ! -e $pk/src/compositor-out && ! -e $pk/src/files-build && ! -e $pk/src/snapshot/old ]] && echo yes)" yes
expect "prepare extracts HEAD with the time of now (a newer VERSION file than the run start)" "$([[ $(stat -c %Y "$pk/src/snapshot/VERSION" 2>/dev/null || echo 0) -ge $started ]] && echo yes)" yes
expect "prepare records the commit" "$(<"$pk/src/BUILD-COMMIT")" "$(git -C "$root" rev-parse HEAD)"

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
out=$("$root/scripts/gates/idle-cpu.sh" --pid "$idle=idle-sleep" --seconds 4 --interval 1 --min-seconds 2 --gate-seconds 1 --real-session 2>&1)
rc=$?
expect "P1 idle process passes" "$rc" 0
expect "P1 prints the verdict with samples" "$([[ $out == *"P1: PASS"*"4 samples"* ]] && echo yes)" yes
out=$("$root/scripts/gates/idle-cpu.sh" --pid "$busy=busy-yes" --seconds 4 --interval 1 --min-seconds 2 --gate-seconds 1 --real-session 2>&1)
rc=$?
expect "P1 busy process fails" "$rc" 1
expect "P1 reports the CPU" "$([[ $out == *"P1: FAIL"* ]] && echo yes)" yes
expect "P1 short window is inconclusive" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$idle" --seconds 3 --interval 1 --min-seconds 100)" 2
expect "P1 without a target is an error" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --seconds 3)" 2
expect "P1 short window is a proxy, never a pass" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$idle" --seconds 3 --interval 1 --min-seconds 2)" 2
# The busy process is allowed when the baseline is as busy.
expect "P1 baseline" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$busy" --baseline-pid "$busy" --seconds 3 --interval 1 --min-seconds 2 --gate-seconds 1 --real-session)" 0
expect "P1 --pid without --real-session is a proxy, never a pass" "$(rc_of "$root/scripts/gates/idle-cpu.sh" --pid "$idle" --seconds 3 --interval 1 --min-seconds 2 --gate-seconds 1)" 2

# P2: a process against a baseline.
mb=$(($(gate_rss_kb "$idle") / 1000))
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
