#!/usr/bin/env bash
# The activity monitor's sampler cost, tab by tab (ADR-0038 d; docs/specs/activity.md AM-P2, acceptance A-P): builds
# activity-sampler-bench, starts the reference fixture of probe A10 as the current user (idle processes with threads and
# open descriptors, loopback TCP connections), measures 101 samples of each tab back to back on the sampler's thread clock,
# and compares each tab's median with its threshold. The fixture is stopped at the end, whatever happens.
#
#   tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only]
#     defaults: 400 processes of 4 threads and 9 extra descriptors each, 100 TCP connections, 101 samples (A10's fixture;
#     the other owners' processes are whatever this machine runs). --report-only prints the numbers and exits 0.
#   Exit 0 every tab within its threshold (or SKIP without g++), 1 a tab over, 2 usage or a refused run.
#
# Run as the user the app will run as, never as root: root reads every process's io and descriptors, which is not the
# user's cost. The thresholds are those of the spec (A10's worst run plus about 30 %, measured on the cloud machine of
# step 0); step 1 records this script's numbers on the reference machine, and the integrator sets them again if they differ.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$root"

processes=400 threads=4 fds=9 tcp=100 samples=101 report=0
while (($#)); do
  case $1 in
    --processes) processes=${2:?}; shift ;;
    --threads) threads=${2:?}; shift ;;
    --fds) fds=${2:?}; shift ;;
    --tcp) tcp=${2:?}; shift ;;
    --samples) samples=${2:?}; shift ;;
    --report-only) report=1 ;;
    *) echo "usage: tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only]" >&2; exit 2 ;;
  esac
  shift
done
[[ $(id -u) != 0 ]] || { echo "refused: run as the app's user, not root (root's reads are not the user's cost)"; exit 2; }
command -v g++ >/dev/null || { echo "SKIP: g++ is not installed"; exit 0; }

declare -A limit=([cpu]=6 [memory]=10 [energy]=13 [disk]=7 [network]=7) # ms per sample, AM-P2

apps/activity/build-direct.sh --bench >/dev/null || { echo "FAIL: building activity-sampler-bench"; exit 1; }
bench=$root/.dev/build/activity-sampler-bench

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

echo "fixture: $processes processes of $threads threads and $fds extra descriptors, $tcp TCP connections; $(nproc) processors"
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
((report)) && exit 0
exit "$status"
