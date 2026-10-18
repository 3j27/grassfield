#!/usr/bin/env bash
# scripts/dev/pidfile.sh: only a record whose start time still matches its process is signalled; a stale, foreign or
# older record never is, nor a compositor, its group or session, nor the caller (incident 2026-10-18: a stale record
# made nested-down.sh kill the owner's Hyprland session). Host-namespace cases skip inside the Claude Code sandbox.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/pidfile.XXXXXX")
fails=0
pass() { echo "PASS: pidfile: $1"; }
fail() { echo "FAIL: pidfile: $1"; fails=$((fails + 1)); }
victim=""
cleanup() {
  [[ -n $victim ]] && kill "$victim" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

# A live process that is not the record's: a plain background sleep.
sleep 60 &
victim=$!

# 1. Right PID, wrong start time (a record from another PID namespace or an earlier boot): not live, nothing signalled.
printf '%s\n' "$victim" >"$tmp/stale.pid"
printf '1\n' >"$tmp/stale.pid.start"
if dev_live_pid "$tmp/stale.pid" >/dev/null; then fail "stale record counted as live"; else pass "stale record is not live"; fi
dev_stop "$tmp/stale.pid" stale 2>/dev/null
if kill -0 "$victim" 2>/dev/null; then pass "stale record: the process was not signalled"; else fail "stale record: the process was signalled"; fi
if [[ ! -e $tmp/stale.pid && ! -e $tmp/stale.pid.start ]]; then pass "stale record removed"; else fail "stale record kept"; fi

# 2. Record without a start time (written by an older script): nothing signalled, the record stays for a manual check.
printf '%s\n' "$victim" >"$tmp/old.pid"
dev_stop "$tmp/old.pid" old 2>/dev/null
if kill -0 "$victim" 2>/dev/null; then pass "record without start time: not signalled"; else fail "record without start time: signalled"; fi
if [[ -e $tmp/old.pid ]]; then pass "record without start time kept"; else fail "record without start time removed"; fi

# 3. PID 1 and garbage are never live records.
printf '1\n' >"$tmp/init.pid"
dev_start_time 1 >"$tmp/init.pid.start" 2>/dev/null || printf '0\n' >"$tmp/init.pid.start"
printf 'x; rm -rf /\n' >"$tmp/junk.pid"
printf '0\n' >"$tmp/junk.pid.start"
if dev_live_pid "$tmp/init.pid" >/dev/null || dev_live_pid "$tmp/junk.pid" >/dev/null; then
  fail "PID 1 or a garbage record counted as live"
else
  pass "PID 1 and garbage records are not live"
fi

if dev_host_namespace; then
  # 4. A matching record of a setsid process: live; dev_stop stops its group. Started through a subshell so that it is
  #    not this script's child (a dead child stays a zombie that `kill -0` still sees).
  (setsid sleep 60 </dev/null >/dev/null 2>&1 & echo $! >"$tmp/own.raw")
  own=$(<"$tmp/own.raw")
  for _ in $(seq 1 20); do [[ $(ps -o comm= -p "$own" 2>/dev/null) == sleep ]] && break; sleep 0.05; done
  dev_record_pid "$tmp/own.pid" "$own"
  if [[ $(dev_live_pid "$tmp/own.pid") == "$own" ]]; then pass "matching record is live"; else fail "matching record not live"; fi
  dev_stop "$tmp/own.pid" own >/dev/null
  for _ in $(seq 1 20); do kill -0 "$own" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$own" 2>/dev/null; then fail "matching record: the process still runs"; kill "$own" 2>/dev/null; else pass "matching record: the process stopped"; fi

  # 5. Never this script, its parent, group or session.
  bad=0
  for p in $$ "$PPID" $(ps -o pgid=,sid= -p $$); do dev_may_signal "$p" && bad=1; done
  if ((bad)); then fail "the caller, its parent, group or session may be signalled"; else pass "the caller, its parent, group and session are protected"; fi

  # 6. Never a running compositor (the owner's when one runs), its group or session.
  hypr=$(pgrep -x Hyprland | head -n 1)
  if [[ -n $hypr ]]; then
    bad=0
    for p in "$hypr" $(ps -o pgid=,sid= -p "$hypr"); do dev_may_signal "$p" && bad=1; done
    if ((bad)); then fail "a compositor, its group or session may be signalled"; else pass "compositors, their groups and sessions are protected"; fi
  else
    echo "SKIP: pidfile: no compositor running"
  fi
else
  echo "SKIP: pidfile: host-namespace cases (sandboxed)"
fi

exit $((fails > 0))
