#!/usr/bin/env bash
# Dock cost with unpinned running apps (the recents loop of the first Dock pass burned ~100 % CPU with 4 or more): the shell's CPU
# over 30 s with 0/4/6/8 foot windows with distinct app ids (started through scripts/dev/isolated.sh by vs_spawn, on the nested
# compositor and its private bus), and how many times grassfield.json is written while they open and close (inotifywait on the
# nested config dir). Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-perf.sh [SECONDS=30]
# Exit status 1 when the CPU of a 30 s window is 5 % or more, or when closing/opening 8 apps writes the file more than 8 times.
source "$(dirname "$0")/lib.sh"

secs=${1:-30}
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${watch_pid:-} ]] && kill "$watch_pid" 2>/dev/null || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

shell_pid() { cat "$VS_DEV/shell.pid" 2>/dev/null; }
# ticks PID: utime + stime of the process and its threads, in clock ticks.
ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }

# cpu SECONDS: CPU percent of the shell over SECONDS.
cpu() {
  local pid a b hz
  pid=$(shell_pid)
  hz=$(getconf CLK_TCK)
  a=$(ticks "$pid")
  sleep "$1"
  b=$(ticks "$pid")
  awk -v a="$a" -v b="$b" -v hz="$hz" -v s="$1" 'BEGIN { printf "%.1f", (b - a) / hz / s * 100 }'
}

vs_session en
vs_reset dark 0.25
cfg=$VS_DEV/config
events=$VS_STATE/perf-events.log
fail=0
printf '%-8s %-14s %s\n' apps "CPU %% (%ss)" "grassfield.json writes (open + close)"
for n in 0 4 6 8; do
  : > "$events"
  inotifywait -m -q -e close_write -e moved_to --format '%f' "$cfg" > "$events" 2>/dev/null &
  watch_pid=$!
  for i in $(seq 1 "$n"); do
    vs_spawn foot --app-id "gfperf$i"
    vs_sleep 1
  done
  vs_sleep 3
  c=$(cpu "$secs")
  vs_kill_clients
  vs_sleep 3
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  watch_pid=""
  w=$(grep -c '^grassfield.json' "$events" || true)
  printf '%-8s %-14s %s\n' "$n" "$c" "$w"
  awk -v c="$c" 'BEGIN { exit !(c + 0 < 5) }' || fail=1
  (( w <= 8 )) || fail=1
done
exit $fail
