#!/usr/bin/env bash
# The activity monitor's sampler cost, tab by tab (ADR-0038 d; docs/specs/activity.md AM-P2, acceptance A-P): builds
# activity-sampler-bench, starts the reference fixture of probe A10 as the current user (idle processes with threads and
# open descriptors, loopback TCP connections), measures 101 samples of each tab back to back on the sampler's thread clock,
# and compares each tab's median with its threshold. The fixture is stopped at the end, whatever happens.
#
#   tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only] [--model]
#     defaults: 400 processes of 4 threads and 9 extra descriptors each, 100 TCP connections, 101 samples (A10's fixture;
#     the other owners' processes are whatever this machine runs). --report-only prints the numbers and exits 0. --model
#     also builds probe A10 (docs/audits/activity-2026-10-28/sampcost.c) and runs it on the same fixture right after, and
#     prints each tab's ratio to A10 reading what the sampler reads (its "step 1" plan; the review of 949fc98 asks for
#     about 1.1); the gate stays the thresholds.
#   Exit 0 every tab within its threshold (or SKIP without g++), 1 a tab over, 2 usage or a refused run.
#
# Run as the user the app will run as, never as root: root reads every process's io and descriptors, which is not the
# user's cost. The thresholds are those of the spec (AM-P2): the integrator set them on the reference machine (i5-10400H,
# 8 threads, kernel 7.2.5, the owner's live session, load 2.0, outside any sandbox) on 2026-10-28 from probe A10's worse of
# two runs at idle plus about 30 % (A10: CPU 13.0, Memory 19.1, Energy 30.8, Disk 13.3, Network 34.6 ms; pull request #40,
# the integrator's comment of 18:59 UTC). Step 0's limits, from the cloud machine, were 6, 10, 13, 7 and 7 ms.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$root"

processes=400 threads=4 fds=9 tcp=100 samples=101 report=0 model=0
while (($#)); do
  case $1 in
    --processes) processes=${2:?}; shift ;;
    --threads) threads=${2:?}; shift ;;
    --fds) fds=${2:?}; shift ;;
    --tcp) tcp=${2:?}; shift ;;
    --samples) samples=${2:?}; shift ;;
    --report-only) report=1 ;;
    --model) model=1 ;;
    *) echo "usage: tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only] [--model]" >&2; exit 2 ;;
  esac
  shift
done
[[ $(id -u) != 0 ]] || { echo "refused: run as the app's user, not root (root's reads are not the user's cost)"; exit 2; }
command -v g++ >/dev/null || { echo "SKIP: g++ is not installed"; exit 0; }

declare -A limit=([cpu]=17 [memory]=25 [energy]=40 [disk]=17 [network]=45) # ms per sample, AM-P2 (reference machine)

apps/activity/build-direct.sh --bench >/dev/null || { echo "FAIL: building activity-sampler-bench"; exit 1; }
bench=$root/.dev/build/activity-sampler-bench
probe=$root/.dev/build/activity-sampcost
if ((model)); then
  gcc -O2 -o "$probe" docs/audits/activity-2026-10-28/sampcost.c -lpthread || { echo "FAIL: building probe A10"; exit 1; }
fi

pids=()
cleanup() {
  for p in "${pids[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
}
trap cleanup EXIT
"$bench" spawn "$processes" "$threads" "$fds" &
pids+=($!)
"$bench" tcp "$tcp" &
pids+=($!)
sleep 3

echo "fixture: $processes processes of $threads threads and $fds extra descriptors, $tcp TCP connections; $(nproc) processors; soft RLIMIT_NOFILE $(ulimit -Sn) (the sampler and the probe raise it)"
echo "machine: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'), kernel $(uname -r)"
out=$("$bench" measure --tab all --samples "$samples") || { echo "FAIL: the bench failed"; exit 1; }
echo "$out"

status=0
while read -r line; do
  tab=$(sed -n 's/^tab \([a-z]*\):.*/\1/p' <<<"$line")
  median=$(sed -n 's/.* median \([0-9.]*\) ms.*/\1/p' <<<"$line")
  [[ -n $tab && -n $median ]] || continue
  if awk -v m="$median" -v l="${limit[$tab]}" 'BEGIN { exit !(m <= l) }'; then
    echo "PASS: $tab median $median ms <= ${limit[$tab]} ms (AM-P2)"
  else
    echo "FAIL: $tab median $median ms > ${limit[$tab]} ms (AM-P2)"
    status=1
  fi
done <<<"$out"
if ((model)); then
  modelOut=$("$probe" measure "$samples") || { echo "FAIL: probe A10 failed"; exit 1; }
  echo "probe A10 on the same fixture:"
  grep -E "raised|listed|could not be opened|per tab|^    (CPU|Memory|Disk|Energy|Network|step 1)" <<<"$modelOut"
  # The ratios compare the same reads: the product against A10's step-1 plan (review of f68789c); the step-0 lines above
  # are the limits' source.
  declare -A modelMs=(
    [cpu]=$(sed -n 's/^    step 1 CPU  *\([0-9.]*\) ms.*/\1/p' <<<"$modelOut")
    [memory]=$(sed -n 's/^    step 1 Memory  *\([0-9.]*\) ms.*/\1/p' <<<"$modelOut")
    [disk]=$(sed -n 's/^    step 1 Disk  *\([0-9.]*\) ms.*/\1/p' <<<"$modelOut")
    [energy]=$(sed -n 's/^    step 1 Energy  *\([0-9.]*\) ms.*/\1/p' <<<"$modelOut")
    [network]=$(sed -n 's/^    step 1 Network  *\([0-9.]*\) ms.*/\1/p' <<<"$modelOut")
  )
  while read -r line; do
    tab=$(sed -n 's/^tab \([a-z]*\):.*/\1/p' <<<"$line")
    median=$(sed -n 's/.* median \([0-9.]*\) ms.*/\1/p' <<<"$line")
    [[ -n $tab && -n $median && -n ${modelMs[$tab]:-} ]] || continue
    awk -v t="$tab" -v p="$median" -v m="${modelMs[$tab]}" 'BEGIN { printf "ratio: %s product %.3f ms / model %.3f ms = %.2f\n", t, p, m, p / m }'
  done <<<"$out"
fi
((report)) && exit 0
exit "$status"
