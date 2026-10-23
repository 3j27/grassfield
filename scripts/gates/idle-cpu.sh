#!/usr/bin/env bash
# Gate P1: idle CPU of grassfield-shell + grassfield-menu-bridge, in percent of ONE core, from /proc/<pid>/stat
# (utime + stime; pidstat/sysstat is not installed). Verdict: PASS when the summed mean CPU over the window is at most
# <baseline> + 0.5 points (master-prompt §10 P1: "baseline + 0.5 pt of one core, 10 min idle"; the baseline is the
# omarchy-shell's idle CPU, 0 when none is given, the strictest reading).
#
#   scripts/gates/idle-cpu.sh [--nested | --real | --pid PID[=label]]... [options]
#     --nested         this tree's nested session: .dev/shell.pid and .dev/menu-bridge.pid (records verified by start time)
#     --real           the owner's real session, READ ONLY: the PIDs of `qs -n -c grassfield` and grassfield-menu-bridge
#                      found with pgrep; nothing is signalled and no compositor, display or socket is touched
#     --pid PID[=label]  a process to measure (repeatable); any process of the same user
#     --baseline-pid PID  the omarchy-shell (or another baseline process) measured at the same time; its mean is the baseline
#     --baseline PCT   a baseline measured earlier (percent of one core), instead of --baseline-pid
#     --seconds N      window length, default 600 (10 minutes)
#     --interval S     sampling period, default 10 s
#     --max-delta PCT  allowed excess over the baseline, default 0.5
#     --min-seconds N  a shorter window is INCONCLUSIVE, default 60 (the 10-minute window is what the gate asks for)
#
# The desktop must be idle (nothing open, nothing moving): the script reports what it measured, not what the screen did.
# Prints per process: pid, name, samples, window, CPU ticks, mean and peak interval CPU; then one verdict line.
# Exit: 0 PASS, 1 FAIL (over the bound, or a measured process vanished), 2 INCONCLUSIVE or usage error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=lib.sh
. "$root/scripts/gates/lib.sh"

seconds=600 interval=10 maxdelta=0.5 minseconds=60 baseline="" baseline_pid="" nested=0 real=0
pids=() labels=()
while (($#)); do
  case $1 in
    --nested) nested=1 ;;
    --real) real=1 ;;
    --pid) shift; pids+=("${1%%=*}"); labels+=("${1#*=}"); [[ $1 == *=* ]] || labels[-1]="" ;;
    --baseline-pid) shift; baseline_pid=$1 ;;
    --baseline) shift; baseline=$1 ;;
    --seconds) shift; seconds=$1 ;;
    --interval) shift; interval=$1 ;;
    --max-delta) shift; maxdelta=$1 ;;
    --min-seconds) shift; minseconds=$1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "idle-cpu: unknown argument $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done
[[ $seconds =~ ^[0-9]+$ && $interval =~ ^[0-9]+$ ]] && ((seconds > 0 && interval > 0)) || { echo "idle-cpu: --seconds and --interval are positive integers" >&2; exit 2; }

if ((nested)); then
  # shellcheck source=../dev/pidfile.sh
  . "$root/scripts/dev/pidfile.sh"
  for rec in shell:grassfield-shell menu-bridge:grassfield-menu-bridge; do
    if p=$(dev_live_pid "$root/.dev/${rec%%:*}.pid"); then pids+=("$p"); labels+=("${rec#*:} (nested)"); else echo "idle-cpu: no live ${rec#*:} of this tree's nested session" >&2; exit 2; fi
  done
fi
if ((real)); then
  while read -r p; do [[ -n $p ]] && { pids+=("$p"); labels+=("grassfield-shell (real session)"); }; done < <(gate_find 'qs -n -c grassfield')
  while read -r p; do [[ -n $p ]] && { pids+=("$p"); labels+=("grassfield-menu-bridge (real session)"); }; done < <(pgrep -u "$(id -u)" -x grassfield-menu-bridge 2>/dev/null)
  ((${#pids[@]} > 0)) || { echo "idle-cpu: no grassfield-shell found in this user's processes (is the real session visible from here? the Claude sandbox hides it: run as a bare command)" >&2; exit 2; }
fi
((${#pids[@]} > 0)) || { echo "idle-cpu: nothing to measure (--nested, --real or --pid)" >&2; exit 2; }
hz=$(getconf CLK_TCK)

declare -A t0=() start=() last=() peak=() gone=()
t_begin=$(date +%s.%N)
for p in "${pids[@]}" ${baseline_pid:+"$baseline_pid"}; do
  t0[$p]=$(gate_ticks "$p") && start[$p]=$(gate_start "$p") || { echo "idle-cpu: cannot read process $p" >&2; exit 2; }
  last[$p]=${t0[$p]}
  peak[$p]=0
done
samples=0
t_prev=$t_begin
end=$(awk -v b="$t_begin" -v s="$seconds" 'BEGIN { printf "%.3f", b + s }')
while awk -v n="$(date +%s.%N)" -v e="$end" 'BEGIN { exit !(n < e) }'; do
  sleep "$interval"
  t_now=$(date +%s.%N)
  elapsed=$(awk -v a="$t_prev" -v b="$t_now" 'BEGIN { printf "%.3f", b - a }')
  samples=$((samples + 1))
  for p in "${pids[@]}" ${baseline_pid:+"$baseline_pid"}; do
    [[ -n ${gone[$p]:-} ]] && continue
    if now=$(gate_ticks "$p") && [[ $(gate_start "$p") == "${start[$p]}" ]]; then
      pct=$(gate_cpu_pct "$((now - last[$p]))" "$elapsed" "$hz")
      awk -v a="$pct" -v b="${peak[$p]}" 'BEGIN { exit !(a > b) }' && peak[$p]=$pct
      last[$p]=$now
    else
      gone[$p]=1
    fi
  done
  t_prev=$t_now
done
window=$(awk -v a="$t_begin" -v b="$t_prev" 'BEGIN { printf "%.0f", b - a }')

fail=0 total=0
for i in "${!pids[@]}"; do
  p=${pids[$i]}
  name=${labels[$i]:-$(gate_comm "$p")}
  if [[ -n ${gone[$p]:-} ]]; then
    echo "P1: $name (pid $p): FAILED the window: the process exited or was replaced during the measurement"
    fail=1
    continue
  fi
  d=$((last[$p] - t0[$p]))
  mean=$(gate_cpu_pct "$d" "$window" "$hz")
  total=$(awk -v a="$total" -v b="$mean" 'BEGIN { printf "%.3f", a + b }')
  echo "P1: $name (pid $p): $d ticks in ${window} s, mean $mean % of one core, peak interval ${peak[$p]} % ($samples samples of ${interval} s)"
done
base=${baseline:-0}
if [[ -n $baseline_pid ]]; then
  if [[ -n ${gone[$baseline_pid]:-} ]]; then echo "P1: the baseline process $baseline_pid vanished: INCONCLUSIVE"; exit 2; fi
  base=$(gate_cpu_pct "$((last[$baseline_pid] - t0[$baseline_pid]))" "$window" "$hz")
  echo "P1: baseline $(gate_comm "$baseline_pid") (pid $baseline_pid): mean $base % over ${window} s"
fi
bound=$(awk -v a="$base" -v b="$maxdelta" 'BEGIN { printf "%.3f", a + b }')
if ((window < minseconds || samples < 3)); then
  echo "P1: INCONCLUSIVE: ${window} s and $samples samples is below the minimum of ${minseconds} s and 3 samples (the gate asks for $seconds s)"
  exit 2
fi
if ((fail)); then echo "P1: FAIL (a measured process vanished); sum $total % of one core"; exit 1; fi
if gate_le "$total" "$bound"; then
  echo "P1: PASS: sum $total % of one core <= $bound % (baseline $base + $maxdelta) over ${window} s, $samples samples, ${#pids[@]} process(es)"
  exit 0
fi
echo "P1: FAIL: sum $total % of one core > $bound % (baseline $base + $maxdelta) over ${window} s, $samples samples, ${#pids[@]} process(es)"
exit 1
