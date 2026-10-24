#!/usr/bin/env bash
# Dated reports for gate runs (GF-036: run artefacts disappeared with removed worktrees, so no result could be re-audited).
# One small wrapper, not a rewrite of the scripts: any gate command runs through it, and a report with the commit, the
# build id, the exit code and the log path is written for every run.
#
#   scripts/dev/gate-run.sh NAME -- COMMAND [ARG...]    run COMMAND, tee its output to a log, write the report, exit with
#                                                       COMMAND's exit code (e.g. `just gate release-check just check`)
#   scripts/dev/gate-run.sh --record NAME EXIT LOG      write the report for a run that already happened (a script that
#                                                       prints its own summary line calls this at its end)
#   scripts/dev/gate-run.sh --archive                   copy the reports (and their logs, tail only when large) of
#                                                       .dev/gate-runs/ into docs/testing/runs/ for the repository
#
# Report: .dev/gate-runs/<UTC stamp>-<name>.md (git-ignored, survives `git clean`-free worktree life) with
#   gate, date (UTC), result (PASS exit 0; NOT JUDGED exit 3, the tests' convention for cases not judged or skipped,
#   e.g. tests/compositor/overview_focus.sh, never a pass; FAIL otherwise; a log line with "NOT VERIFIED" or "SKIP" is counted and
#   named, never hidden), exit code, commit (+dirty), branch, build id (VERSION file, built plugin and its hash), log
#   path and its sha256, counts of PASS/FAIL/SKIP/NOT VERIFIED/PROXY lines, and the core dumps made during the run
#   (scripts/dev/coredump-summary.py, read-only coredumpctl).
# Environment (tests): GATE_RUNS_DIR (default .dev/gate-runs), GATE_ARCHIVE_DIR (default docs/testing/runs),
# GATE_STAMP (fixed timestamp).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
runs=${GATE_RUNS_DIR:-$root/.dev/gate-runs}
archive=${GATE_ARCHIVE_DIR:-$root/docs/testing/runs}
max_log=262144 # bytes archived whole; a larger log is archived as its last 2000 lines

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "gate-run: $*" >&2; exit 2; }
valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# The build id: what was built from, as far as the checkout says. Never fails.
build_id() {
  local parts=() v=""
  [[ -r $root/VERSION ]] && v=$(tr -d '[:space:]' <"$root/VERSION") && parts+=("version $v")
  local so=$root/compositor/build/grassfield-compositor.so
  if [[ -f $so ]]; then
    parts+=("plugin $(sha256sum "$so" | cut -c1-12)")
  fi
  [[ -f $root/packaging/arch/PKGBUILD ]] && {
    local pv pr
    pv=$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$root/packaging/arch/PKGBUILD" | head -n1)
    pr=$(sed -n 's/^pkgrel=\(.*\)$/\1/p' "$root/packaging/arch/PKGBUILD" | head -n1)
    [[ -n $pv && $pv != *'$'* ]] && parts+=("pkgver $pv-${pr:-?}")
  }
  ((${#parts[@]})) || parts+=("none (no VERSION file, no built plugin)")
  local IFS=';'
  echo "${parts[*]}"
}

count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

write_report() { # NAME EXIT LOG
  local name=$1 rc=$2 log=$3
  local stamp=${GATE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
  mkdir -p "$runs" || die "cannot create $runs"
  local report=$runs/$stamp-$name.md
  local commit dirty branch result
  commit=$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
  # Untracked files count: a clean tracked tree with a stray new file did not run from the commit alone.
  if [[ -z $(git -C "$root" status --porcelain 2>/dev/null) ]]; then dirty=clean; else dirty="dirty: tracked changes or untracked files"; fi
  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  case $rc in
    0) result=PASS ;;
    3) result="NOT JUDGED" ;;
    *) result=FAIL ;;
  esac
  local logsum=n/a pass=0 fail=0 skip=0 nv=0 proxy=0
  if [[ -f $log ]]; then
    logsum=$(sha256sum "$log" | cut -d' ' -f1)
    pass=$(count '^PASS\|: PASS\| PASS ' "$log"); fail=$(count '^FAIL\|: FAIL\| FAIL ' "$log")
    skip=$(count 'SKIP' "$log"); nv=$(count 'NOT VERIFIED' "$log"); proxy=$(count 'PROXY' "$log")
  fi
  {
    echo "# Gate run: $name"
    echo
    echo "- gate: $name"
    echo "- date: $(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$stamp")"
    echo "- result: $result"
    echo "- exit code: $rc"
    echo "- commit: $commit ($dirty) on $branch"
    echo "- build id: $(build_id)"
    echo "- log: $log"
    echo "- log sha256: $logsum"
    echo "- lines: PASS $pass, FAIL $fail, SKIP $skip, NOT VERIFIED $nv, PROXY $proxy"
    if [[ -s ${log%.log}.coredumps ]]; then
      echo "- coredumps: $(head -n1 "${log%.log}.coredumps") (details: ${log%.log}.coredumps)"
    fi
    # "result" is the exit status; "verdict" says what that is worth.
    if [[ $rc == 3 ]]; then
      echo "- verdict: NOT JUDGED (exit 3: the test judged only part of its cases, or skipped; not a pass, read the log)"
    elif [[ $rc != 0 ]]; then
      echo "- verdict: FAIL (exit $rc)"
    elif ((fail > 0)); then
      echo "- verdict: FAIL ($fail FAIL line(s) in the log although the exit code is 0: any FAIL line means FAIL)"
    elif ((skip + nv + proxy > 0)); then
      echo "- verdict: exit 0 with caveats (SKIP $skip, NOT VERIFIED $nv, PROXY $proxy): not a measured pass of the gate"
    elif ((pass == 0)); then
      echo "- verdict: NOT VERIFIED (exit 0 but the log has no PASS line: nothing in it says that anything was measured)"
    else
      echo "- verdict: measured pass (no SKIP, NOT VERIFIED or PROXY line)"
    fi
    if ((skip + nv + proxy > 0)); then
      echo "- note: this run is not a plain pass: SKIP, NOT VERIFIED and PROXY lines are listed in the log; read them before citing it"
    fi
  } >"$report"
  echo "gate-run: $result ($name, exit $rc) report $report" >&2
}

case ${1:-} in
  -h | --help | "") usage; [[ -n ${1:-} ]] && exit 0; exit 2 ;;
  --record)
    [[ $# -eq 4 ]] || die "usage: --record NAME EXIT LOG"
    valid_name "$2" || die "bad gate name '$2' (a-z, 0-9, . _ -)"
    [[ $3 =~ ^[0-9]+$ ]] || die "EXIT must be a number"
    write_report "$2" "$3" "$4"
    ;;
  --archive)
    shopt -s nullglob
    reports=("$runs"/*.md)
    ((${#reports[@]})) || { echo "gate-run: nothing to archive in $runs" >&2; exit 0; }
    mkdir -p "$archive" || die "cannot create $archive"
    n=0
    for r in "${reports[@]}"; do
      base=$(basename "$r" .md)
      log=$(sed -n 's/^- log: //p' "$r" | head -n1)
      cp -- "$r" "$archive/$base.md"
      if [[ -f $log ]]; then
        if (($(stat -c %s "$log") <= max_log)); then cp -- "$log" "$archive/$base.log"; else tail -n 2000 -- "$log" | sed -e "\$a\\" >"$archive/$base.log"; echo "(archived: last 2000 lines only; full log was $log)" >>"$archive/$base.log"; fi
      fi
      [[ -f ${log%.log}.coredumps ]] && cp -- "${log%.log}.coredumps" "$archive/$base.coredumps"
      n=$((n + 1))
    done
    echo "gate-run: archived $n report(s) to $archive (review, then commit)" >&2
    ;;
  *)
    name=$1
    shift
    valid_name "$name" || die "bad gate name '$name' (a-z, 0-9, . _ -)"
    [[ ${1:-} == -- ]] || die "usage: gate-run.sh NAME -- COMMAND [ARG...]"
    shift
    (($#)) || die "no command"
    mkdir -p "$runs" || die "cannot create $runs"
    stamp=${GATE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
    log=$runs/$stamp-$name.log
    started=$(date "+%Y-%m-%d %H:%M:%S")
    "$@" 2>&1 | tee -- "$log"
    rc=${PIPESTATUS[0]}
    # GF-082: dumps made while the gate ran, attributed (read-only coredumpctl list/info, never a core file).
    python3 -I "$root/scripts/dev/coredump-summary.py" --since "$started" >"${log%.log}.coredumps" 2>/dev/null || rm -f -- "${log%.log}.coredumps"
    GATE_STAMP=$stamp write_report "$name" "$rc" "$log"
    exit "$rc"
    ;;
esac
