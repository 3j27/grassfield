#!/usr/bin/env bash
# The activity monitor's sampler cost, tab by tab (ADR-0038 d; docs/specs/activity.md AM-P2, acceptance A-P): builds
# activity-sampler-bench and probe A10 (docs/audits/activity-2026-10-28/sampcost.c), starts the reference fixture of A10 as
# the current user (idle processes with threads and open descriptors, loopback TCP connections), runs A10, measures 101
# samples of each tab back to back on the sampler's thread clock, runs A10 again, and compares each tab's median with its
# limit. The fixture is stopped at the end, whatever happens.
#
#   tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only]
#     defaults: 400 processes of 4 threads and 9 extra descriptors each, 100 TCP connections, 101 samples (A10's fixture;
#     the other owners' processes are whatever this machine runs). --report-only prints the numbers and exits 0. --model,
#     which used to add A10's run, is accepted and changes nothing: A10 always runs now.
#   Exit 0 every tab within its limit (or SKIP without gcc and g++), 1 a tab over, 2 usage or a refused run (also a run
#   started at a load average of 2 or more: its numbers print and do not count).
#
# Run as the user the app will run as, never as root: root reads every process's io and descriptors, which is not the
# user's cost. The limits (AM-P2; ADR-0038, the integrator's decisions on pull request #47, 2026-10-29): each tab's limit
# is 1.3 x A10 reading what the sampler reads (its "step 1" plan), the worse of A10's two runs on this fixture, before and
# after the product's. So a product more than 1.3 x its own plan fails on any machine, and a load change between the runs
# moves the plan and the product together. Disk's plan is A10's one pass over the same files in the sampler's order
# ("step 1 Disk, in one pass"): the summed plan, whose parts are each measured alone with warm caches, is below what any
# reader of those files pays (the product reading them and parsing nothing was 1.25-1.41 x it). Both Disk lines print.
# Disk's margin is 1.15, not 1.3 (the integrator's decision for step 2b, after #47's merge: Disk at most 1.15 x its one-pass
# line, measured at a load under 2). The step-0 limits came from A10's step-0 plan (CPU 13.0 x 1.3 = 17 ms on the
# reference machine), which step 1 changed on purpose (AD32, AD33, the owners' turns); the reference machine's numbers
# come from the integrator's run at idle.
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
    --model) ;;
    *) echo "usage: tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--report-only]" >&2; exit 2 ;;
  esac
  shift
done
[[ $(id -u) != 0 ]] || { echo "refused: run as the app's user, not root (root's reads are not the user's cost)"; exit 2; }
command -v g++ >/dev/null && command -v gcc >/dev/null || { echo "SKIP: gcc or g++ is not installed"; exit 0; }

margin=1.3 # AM-P2: a tab's limit is its step-1 plan times this
disk_margin=1.15 # Disk's, against its one-pass line (step 2b)
max_load=2 # a run started at this load average or more does not count (step 2b)

apps/activity/build-direct.sh --bench >/dev/null || { echo "FAIL: building activity-sampler-bench"; exit 1; }
bench=$root/.dev/build/activity-sampler-bench
probe=$root/.dev/build/activity-sampcost
gcc -O2 -o "$probe" docs/audits/activity-2026-10-28/sampcost.c -lpthread || { echo "FAIL: building probe A10"; exit 1; }

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
load=$(cut -d' ' -f1 /proc/loadavg)
echo "load average at the start: $load (a run counts under $max_load)"
# A10's step-1 plan of each tab: the worse of its two runs.
declare -A plan=()
model() { # <run label>: runs A10, prints what it read, keeps each tab's worse step-1 plan
  local out tab name ms
  out=$("$probe" measure "$samples") || { echo "FAIL: probe A10 failed"; exit 1; }
  echo "probe A10 ($1):"
  grep -E "raised|listed|could not be opened|per tab|^    (CPU|Memory|Disk|Energy|Network|step 1|fdinfo of)" <<<"$out"
  for tab in cpu memory energy disk network; do
    name=$(sed 's/^./\U&/' <<<"$tab")
    [[ $tab == cpu ]] && name=CPU
    [[ $tab == disk ]] && name="Disk, in one pass (the sampler's order)" # the integrator's decision of 2026-10-29
    ms=$(sed -n "s/^    step 1 $name  *\([0-9.]*\) ms.*/\1/p" <<<"$out")
    [[ -n $ms ]] || { echo "FAIL: probe A10 printed no step-1 plan for $tab"; exit 1; }
    if [[ -z ${plan[$tab]:-} ]] || awk -v a="$ms" -v b="${plan[$tab]}" 'BEGIN { exit !(a > b) }'; then
      plan[$tab]=$ms
    fi
  done
}

model "before the product"
out=$("$bench" measure --tab all --samples "$samples") || { echo "FAIL: the bench failed"; exit 1; }
echo "$out"
model "after the product"

status=0
while read -r line; do
  tab=$(sed -n 's/^tab \([a-z]*\):.*/\1/p' <<<"$line")
  median=$(sed -n 's/.* median \([0-9.]*\) ms.*/\1/p' <<<"$line")
  [[ -n $tab && -n $median && -n ${plan[$tab]:-} ]] || continue
  k=$margin kind="step 1"
  [[ $tab == disk ]] && k=$disk_margin kind="step 1 in one pass"
  limit=$(awk -v p="${plan[$tab]}" -v k="$k" 'BEGIN { printf "%.3f", p * k }')
  ratio=$(awk -v m="$median" -v p="${plan[$tab]}" 'BEGIN { printf "%.2f", m / p }')
  echo "plan: $tab $kind ${plan[$tab]} ms (the worse A10 run), limit $limit ms ($k x)"
  if awk -v m="$median" -v l="$limit" 'BEGIN { exit !(m <= l) }'; then
    echo "PASS: $tab median $median ms <= $limit ms, $ratio x its plan (AM-P2)"
  else
    echo "FAIL: $tab median $median ms > $limit ms, $ratio x its plan (AM-P2)"
    status=1
  fi
done <<<"$out"
echo "load average at the end: $(cut -d' ' -f1 /proc/loadavg)"
((report)) && exit 0
if awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l >= m) }'; then
  echo "NOT COUNTED: started at a load average of $load, $max_load or more (AM-P2); run again on a quieter machine"
  exit 2
fi
exit "$status"
