#!/usr/bin/env bash
# Gate R1 (master-prompt section 10): shell crash recovery, restart <= 3 s via the systemd user unit, state restored
# (GF-008 residual tool). Honest verdicts:
#
#   PASS / FAIL   --journal: from the REAL unit's journal (read-only `journalctl --user`): every restart the unit made after the
#                 shell's process ended (a crash or a kill: "Main process exited" without a stop of the session) is timed from
#                 the exit to the new shell's "grassfield-shell: started" line, and the state words of that line (lock state,
#                 recent items) are compared with the previous start's. A clean logout (the unit stopped, not restarted)
#                 is not a restart. PASS needs at least one restart and all within the limit with the lock state unchanged.
#   PROXY         --nested: restarts the NESTED dev shell with scripts/dev/shell-run.sh (the dev launcher, not the unit) and times
#                 the way back to a ready `qs ipc ... capabilities status`: the shell's own start time, a lower bound of R1.
#   NOT VERIFIED  no restart in the journal yet (the unit restarts only after a crash), no journal access, no nested session.
#
#   scripts/gates/r1-restart.sh [--journal [--since TIME]] [--nested] [--limit-ms 3000]
#
# The real unit is never started or stopped by this script (journal reading only). To produce a restart on purpose in the
# real session the owner runs, bare: `kill -SEGV $(systemctl --user show -p MainPID --value grassfield-shell.service)`
# (the unit restarts the shell after 1 s; the compositor keeps any lock), then this script with --journal.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
limit=3000
journal=0
nested=0
since="7 days ago"
while (($#)); do
  case $1 in
    --journal) journal=1; shift ;;
    --since) since=${2:?}; shift 2 ;;
    --nested) nested=1; shift ;;
    --limit-ms) limit=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "r1: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ $limit =~ ^[0-9]+$ ]] || { echo "r1: --limit-ms is a number" >&2; exit 2; }
((journal || nested)) || journal=1
status=0
report() { printf 'R1 %s: %s %s\n' "$1" "$2" "$3"; }

# A restart is counted only when systemd logged "Scheduled restart job" after the exit: a logout (the unit stopped, a login
# later) is not one.
# Pure analysis of "journalctl -o short-iso-precise" text on stdin: prints "restarts N worst_ms W state_changes C" and one line
# per restart. Separated so tests/shell/r1_gate.sh can feed fixtures.
analyse() {
  python3 -I -c '
import re, sys
from datetime import datetime
def ts(line):
    return datetime.fromisoformat(re.match(r"(\S+)", line).group(1)).timestamp()
exit_t = None
sched = False
last_state = None
restarts = []
for line in sys.stdin:
    if "grassfield-shell.service: Main process exited" in line:
        exit_t = ts(line)
        sched = False
    elif "grassfield-shell.service: Scheduled restart job" in line:
        sched = True  # the unit itself schedules the restart: a crash or a kill, not a logout
    elif re.search(r"systemd\[\d+\]: (Stopped|Stopping) Grassfield shell", line) and exit_t is not None:
        pass
    m = re.search(r"grassfield-shell: started, .*", line)
    if m:
        state = re.sub(r"plugin protocol \S+ ", "", m.group(0))
        t = ts(line)
        # A restart: the process exited and a new one started within a minute (a later start is a new login).
        if exit_t is not None and sched and 0 <= t - exit_t < 60:
            restarts.append((round((t - exit_t) * 1000), state, last_state))
        exit_t = None
        sched = False
        last_state = state
worst = max((r[0] for r in restarts), default=0)
changed = sum(1 for r in restarts if r[2] is not None and r[1].split("lock")[1].split()[0:1] != r[2].split("lock")[1].split()[0:1]) if restarts else 0
print("restarts %d worst_ms %d state_changes %d" % (len(restarts), worst, changed))
for ms, state, prev in restarts:
    print("  %d ms: %s (previous start: %s)" % (ms, state, prev))
'
}

if ((journal)); then
  if [[ -z ${R1_JOURNAL_FILE:-} ]] && ! command -v journalctl >/dev/null; then
    report journal "NOT VERIFIED" "(journalctl not installed)"
  else
    if [[ -n ${R1_JOURNAL_FILE:-} ]]; then text=$(<"$R1_JOURNAL_FILE"); else
      text=$(journalctl --user -u grassfield-shell.service --since "$since" -o short-iso-precise --no-pager 2>/dev/null) || text=""
    fi
    if [[ -z $text ]]; then
      report journal "NOT VERIFIED" "(no journal of grassfield-shell.service since $since, or no access)"
    else
      out=$(analyse <<<"$text")
      head -n1 <<<"$out"
      tail -n +2 <<<"$out"
      read -r _ n _ worst _ changed <<<"$(head -n1 <<<"$out")"
      if ((n == 0)); then
        report journal "NOT VERIFIED" "(no restart of the unit since $since: it restarts only after a crash or a kill)"
      elif ((worst > limit)); then
        report journal FAIL "($n restart(s), worst $worst ms, limit $limit ms)"
        status=1
      elif ((changed > 0)); then
        report journal FAIL "($n restart(s) within $limit ms but the lock state differed after $changed of them)"
        status=1
      else
        report journal PASS "($n restart(s), worst $worst ms <= $limit ms, lock state restored)"
      fi
    fi
  fi
fi

if ((nested)); then
  dev=$root/.dev
  # shellcheck source=../dev/pidfile.sh
  . "$root/scripts/dev/pidfile.sh"
  if ! dev_nested_target "$dev" 2>/dev/null; then
    report nested "NOT VERIFIED" "(no live nested session of this tree: just nested-up first)"
  else
    t0=$(date +%s%N)
    if ! "$root/scripts/dev/shell-run.sh" >/dev/null 2>&1; then
      report nested "NOT VERIFIED" "(shell-run.sh failed)"
    else
      pid=$(cat "$dev/shell.pid" 2>/dev/null | awk '{print $1}')
      ready=""
      for _ in $(seq 1 100); do
        out=$(qs ipc --pid "$pid" call capabilities status 2>/dev/null) && [[ $out == ready* ]] && { ready=1; break; }
        sleep 0.05
      done
      ms=$((($(date +%s%N) - t0) / 1000000))
      if [[ -z $ready ]]; then
        report nested FAIL "(the nested shell was not ready after $ms ms)"
        status=1
      elif ((ms > limit)); then
        report nested FAIL "(nested restart to ready: $ms ms > $limit ms; includes the dev launcher)"
        status=1
      else
        report nested PROXY "(nested restart to ready: $ms ms <= $limit ms via the dev launcher, not the unit: a lower bound of R1)"
      fi
    fi
  fi
fi
exit "$status"
