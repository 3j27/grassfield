#!/usr/bin/env bash
# The activity monitor's sampler cost, tab by tab (ADR-0038 d; docs/specs/activity.md AM-P2, acceptance A-P): builds
# activity-sampler-bench and probe A10 (tests/tools/sampcost/sampcost.c), starts the reference fixture of A10 as
# the current user (idle processes with threads and open descriptors, loopback TCP connections), runs A10, measures 101
# samples of each tab back to back on the sampler's thread clock, runs A10 again, and compares each tab's median with its
# limit. The fixture is stopped at the end, whatever happens.
#
#   tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--changing P] [--report-only]
#     defaults: 400 processes of 4 threads and 9 extra descriptors each, 100 TCP connections, 101 samples (A10's fixture;
#     the other owners' processes are whatever this machine runs). --report-only prints the numbers and exits 0. --model,
#     which used to add A10's run, is accepted and changes nothing: A10 always runs now.
#     --changing P (default 10; 0 skips it): then Disk is measured again on the same fixture where P % of the processes
#     change their stat and io lines between two samples (the bench pokes them outside the measured time), against A10's
#     one pass on that fixture, at the same 1.15 margin: an idle fixture favours the sampler's unchanged-line cache
#     (review of PR #53). The run fails if the fixture did not change: fewer stat or io lines parsed a sample than 90 % of
#     its changing processes.
#   Exit 0 every tab within its limit (or SKIP without gcc and g++), 1 a tab over or a fixture that did not change, 2 usage
#   or a refused run (also a run started at a load average of 2 or more: its numbers print and do not count).
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

processes=400 threads=4 fds=9 tcp=100 samples=101 report=0 changing=10
while (($#)); do
  case $1 in
    --processes) processes=${2:?}; shift ;;
    --threads) threads=${2:?}; shift ;;
    --fds) fds=${2:?}; shift ;;
    --tcp) tcp=${2:?}; shift ;;
    --samples) samples=${2:?}; shift ;;
    --changing) changing=${2:?}; shift ;;
    --report-only) report=1 ;;
    --model) ;;
    *) echo "usage: tests/apps/activity_cost.sh [--processes N] [--threads T] [--fds F] [--tcp K] [--samples S] [--changing P] [--report-only]" >&2; exit 2 ;;
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
gcc -O2 -o "$probe" tests/tools/sampcost/sampcost.c -lpthread || { echo "FAIL: building probe A10"; exit 1; }

pids=()
tmp=$(mktemp -d)
cleanup() {
  for p in "${pids[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
"$bench" spawn "$processes" "$threads" "$fds" &
spawned=$!
pids+=($spawned)
"$bench" tcp "$tcp" &
pids+=($!)
sleep 3

echo "fixture: $processes processes of $threads threads and $fds extra descriptors, $tcp TCP connections; $(nproc) processors; soft RLIMIT_NOFILE $(ulimit -Sn) (the sampler and the probe raise it)"
echo "machine: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'), kernel $(uname -r)"
# A10's step-1 plan of each tab: the worse of its two runs.
declare -A plan=()
model() { # <run label> [poked group]: runs A10, prints what it read, keeps each tab's worse step-1 plan
  local out tab name ms
  out=$("$probe" measure "$samples" ${2:-}) || { echo "FAIL: probe A10 failed"; exit 1; }
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

# The load average just before the measures (the builds above are done), and the worse of the phases' (review of PR #53).
load=$(cut -d' ' -f1 /proc/loadavg)
echo "load average before the measures: $load (a run counts under $max_load)"
model "before the product"
out=$("$bench" measure --tab all --samples "$samples") || { echo "FAIL: the bench failed"; exit 1; }
echo "$out"
model "after the product"

verdicts=() status=0
judge() { # <label> <bench line> <plan ms> <margin> <kind>
  local median limit ratio
  median=$(sed -n 's/.* median \([0-9.]*\) ms.*/\1/p' <<<"$2")
  limit=$(awk -v p="$3" -v k="$4" 'BEGIN { printf "%.3f", p * k }')
  ratio=$(awk -v m="$median" -v p="$3" 'BEGIN { printf "%.2f", m / p }')
  echo "plan: $1 $5 $3 ms (the worse A10 run), limit $limit ms ($4 x)"
  if awk -v m="$median" -v l="$limit" 'BEGIN { exit !(m <= l) }'; then
    verdicts+=("PASS: $1 median $median ms <= $limit ms, $ratio x its plan (AM-P2)")
  else
    verdicts+=("FAIL: $1 median $median ms > $limit ms, $ratio x its plan (AM-P2)")
    status=1
  fi
}
while read -r line; do
  tab=$(sed -n 's/^tab \([a-z]*\):.*/\1/p' <<<"$line")
  [[ -n $tab && -n ${plan[$tab]:-} ]] || continue
  if [[ $tab == disk ]]; then
    judge disk "$line" "${plan[$tab]}" "$disk_margin" "step 1 in one pass"
  else
    judge "$tab" "$line" "${plan[$tab]}" "$margin" "step 1"
  fi
done <<<"$out"

# Disk again, a part of the fixture changing between two samples.
if ((changing > 0)); then
  pkill -P "$spawned" 2>/dev/null
  kill "$spawned" 2>/dev/null
  wait "$spawned" 2>/dev/null
  every=$(((100 + changing / 2) / changing))
  "$bench" spawn "$processes" "$threads" "$fds" "$every" "$tmp/group" &
  spawned=$!
  pids+=($spawned)
  sleep 3
  group=$(cat "$tmp/group" 2>/dev/null)
  [[ $group =~ ^[0-9]+$ && $group != 0 ]] || { echo "FAIL: the changing fixture did not start"; exit 1; }
  echo "fixture again: every ${every}th of its $processes processes changes its stat and io lines between two samples"
  changed_load=$(cut -d' ' -f1 /proc/loadavg)
  echo "load average before these measures: $changed_load"
  awk -v a="$changed_load" -v b="$load" 'BEGIN { exit !(a > b) }' && load=$changed_load
  unset 'plan[disk]'
  # A10's one pass pokes the group between its rounds as the bench does between its samples: both pay the same machine.
  model "before the product, the fixture changing" "$group"
  disk=$("$bench" measure --tab disk --samples "$samples" --poke "$group") || { echo "FAIL: the bench failed"; exit 1; }
  echo "$disk"
  model "after the product, the fixture changing" "$group"
  judge "disk ($changing % changing)" "$disk" "${plan[disk]}" "$disk_margin" "step 1 in one pass"
  # The fixture really changed (the review of 91dcb63: with transparent huge pages its stat lines seldom did): at each
  # sample the bench parsed again the stat and io lines of at least 90 % of its changing processes.
  changers=$(((processes + every - 1) / every))
  read -r parsed_stat parsed_io < <(sed -n 's/.*lines parsed a sample: stat \([0-9.]*\) io \([0-9.]*\).*/\1 \2/p' <<<"$disk")
  if awk -v s="${parsed_stat:-0}" -v i="${parsed_io:-0}" -v c="$changers" 'BEGIN { exit !(s >= 0.9 * c && i >= 0.9 * c) }'; then
    verdicts+=("PASS: the fixture changed: stat ${parsed_stat} and io ${parsed_io} lines parsed a sample, $changers processes changing")
  else
    verdicts+=("FAIL: the fixture did not change: stat ${parsed_stat:-?} and io ${parsed_io:-?} lines parsed a sample, under 90 % of its $changers changing processes")
    status=1
  fi
fi

printf '%s\n' "${verdicts[@]}"
echo "load average: $load before the measures (the worse phase), $(cut -d' ' -f1 /proc/loadavg) at the end"
((report)) && exit 0
if awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l >= m) }'; then
  echo "NOT COUNTED: the measures started at a load average of $load, $max_load or more (AM-P2); run again on a quieter machine"
  exit 2
fi
exit "$status"
