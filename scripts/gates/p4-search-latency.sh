#!/usr/bin/env bash
# Gate P4 (master-prompt section 10): Search file results <= 300 ms on 100k files; app results <= 50 ms per keystroke
# (GF-008 residual tool). Honest verdicts, never a PASS the measurement cannot support:
#
#   PROXY         the file provider alone (the same plocate argv as shell/search/Search.qml, on a fixture of N files) is within
#                 the limit. It excludes the shell's merge, ranking and render: a lower bound, not the gate.
#   PASS / FAIL   only from the shell's own timestamps (--shell-log-apps: a log of a real shell that ran the queries, lines
#                 "search keystroke->results M ms"). The shell does not yet timestamp file results end to end (its line
#                 "search files via ... merge M ms", --shell-log-files, is the merge only): that stays PROXY until it does.
#   NOT VERIFIED  no tool, no fixture, or no log to judge from.
#
#   scripts/gates/p4-search-latency.sh [--files N] [--runs N] [--limit-ms 300]
#                                      [--shell-log-files FILE] [--shell-log-apps FILE] [--keep]
#
# Fixture: N empty files (default 100000) in 1000 directories under .dev/p4-fixture (git-ignored), indexed with the user-mode
# `updatedb -l 0 -U <root> -o <db>`; nothing outside .dev is read or written, no root. Bare nested measurement (ask the owner):
#   GRASSFIELD_SEARCH_ROOT=$PWD/.dev/p4-fixture/root GRASSFIELD_SEARCH_PLOCATE_DB=$PWD/.dev/p4-fixture/plocate.db just nested-up
#   then `scripts/nestctl`-free IPC: for t in alpha report 4711 zzz; do qs ipc --pid <nested shell pid> call search query "$t"; done
#   and give the shell log: scripts/gates/p4-search-latency.sh --files 0 --shell-log-files .dev/shell.log
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
files=100000
runs=30
limit=300
log_files=""
log_apps=""
keep=0
while (($#)); do
  case $1 in
    --files) files=${2:?}; shift 2 ;;
    --runs) runs=${2:?}; shift 2 ;;
    --limit-ms) limit=${2:?}; shift 2 ;;
    --shell-log-files) log_files=${2:?}; shift 2 ;;
    --shell-log-apps) log_apps=${2:?}; shift 2 ;;
    --keep) keep=1; shift ;;
    -h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "p4: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ $files =~ ^[0-9]+$ && $runs =~ ^[0-9]+$ && $limit =~ ^[0-9]+$ ]] || { echo "p4: numbers only" >&2; exit 2; }
fixture=${P4_FIXTURE_DIR:-$root/.dev/p4-fixture}
status=0

report() { # <name> <verdict> <detail>
  printf 'P4 %s: %s %s\n' "$1" "$2" "$3"
}

# p95 and max of a list of integers (stdin, one per line)
stats() { sort -n | awk '{a[NR]=$1} END {if (NR==0) {print "none"; exit} i=int(NR*0.95); if (i<1) i=1; printf "n=%d median=%d p95=%d max=%d", NR, a[int((NR+1)/2)], a[i], a[NR]}'; }
p95_of() { sort -n | awk '{a[NR]=$1} END {if (NR==0) {print -1; exit} i=int(NR*0.95); if (i<1) i=1; print a[i]}'; }

# ---- the provider alone on a fixture (PROXY) -----------------------------------------------------------------------
if ((files > 0)); then
  if ! command -v plocate >/dev/null || ! command -v updatedb >/dev/null; then
    report files "NOT VERIFIED" "(plocate/updatedb not installed)"
  else
    rm -rf -- "$fixture"
    mkdir -p -- "$fixture/root" || { report files "NOT VERIFIED" "(cannot create $fixture)"; exit 1; }
    python3 -I - "$fixture/root" "$files" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
words = ["alpha", "report", "invoice", "holiday", "notes", "draft", "photo", "budget", "meeting", "archive"]
for i in range(n):
    d = os.path.join(root, "dir%04d" % (i % 1000))
    if i < 1000:
        os.mkdir(d)
    # deterministic names: a word, the index and an extension, like a real home directory's mix
    open(os.path.join(d, "%s-%d.%s" % (words[i % len(words)], i, ("txt", "pdf", "jpg")[i % 3])), "w").close()
PY
    if ! updatedb -l 0 -U "$fixture/root" -o "$fixture/plocate.db" 2>"$fixture/updatedb.err"; then
      report files "NOT VERIFIED" "(updatedb failed: $(head -n1 "$fixture/updatedb.err"))"
    else
      times=()
      # Search.qml's argv: plocate -i -b -l 1500 -d <db> -- <term>; terms of one, three and many hits, and none.
      for term in alpha report 4711 zzzz notes-9; do
        for ((r = 0; r < runs; r++)); do
          t0=$(date +%s%N)
          timeout 2 plocate -i -b -l 1500 -d "$fixture/plocate.db" -- "$term" >/dev/null 2>&1
          t1=$(date +%s%N)
          times+=($(((t1 - t0) / 1000000)))
        done
      done
      summary=$(printf '%s\n' "${times[@]}" | stats)
      p95=$(printf '%s\n' "${times[@]}" | p95_of)
      count=$(find "$fixture/root" -type f | wc -l)
      detail="plocate on $count files, $summary ms (limit $limit ms; excludes the shell's merge, ranking and render)"
      if ((count < files)); then
        report files "NOT VERIFIED" "(fixture has $count of $files files)"
      elif ((p95 > limit)); then
        report files FAIL "$detail"
        status=1
      else
        report files PROXY "$detail"
      fi
    fi
    ((keep)) || rm -rf -- "$fixture"
  fi
fi

# ---- the shell's own timestamps (PASS / FAIL) ----------------------------------------------------------------------
judge_log() { # <name> <file> <regex for the ms field> <limit> <verdict when within the limit> <what the number covers>
  local name=$1 file=$2 re=$3 lim=$4 good=$5 covers=$6 vals n p
  if [[ ! -r $file ]]; then report "$name" "NOT VERIFIED" "(log $file not readable)"; return; fi
  vals=$(sed -n -E "s/.*$re.*/\1/p" "$file")
  n=$(grep -c . <<<"$vals" || true)
  if [[ -z $vals ]] || ((n == 0)); then report "$name" "NOT VERIFIED" "(no matching lines in $file)"; return; fi
  p=$(p95_of <<<"$vals")
  if ((p > lim)); then
    report "$name" FAIL "shell log: $(stats <<<"$vals") ms (limit $lim ms; $covers)"
    status=1
  else
    report "$name" "$good" "shell log: $(stats <<<"$vals") ms (limit $lim ms; $covers)"
  fi
}
[[ -n $log_files ]] && judge_log "file results (shell)" "$log_files" 'search files via [a-z]+ [0-9]+ results, merge ([0-9]+) ms' "$limit" PROXY "the shell logs only the merge of the results into the list, not provider time or render: a lower bound"
[[ -n $log_apps ]] && judge_log "app results per keystroke (shell)" "$log_apps" 'search keystroke->results ([0-9]+) ms' 50 PASS "keystroke to results computed in the shell; render not included"
if ((files == 0)) && [[ -z $log_files && -z $log_apps ]]; then
  report all "NOT VERIFIED" "(nothing to measure: no fixture and no shell log)"
fi
exit "$status"
