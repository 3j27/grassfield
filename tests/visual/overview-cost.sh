#!/usr/bin/env bash
# Spike S4 (docs/specs/overview.md "S4 results", "Measuring P3 and S4"): the cost of the Overview thumbnails of 9 windows (v1,
# ScreencopyView; the plugin is not loaded here), per material profile. CPU of the shell and of the nested Hyprland as a share
# of one core, from /proc/<pid>/stat over SECONDS, and the RSS of both, with the Overview closed and open, for the profiles
# full (live capture), balanced (4 fps) and reduced (one snapshot). The table is printed as markdown to be pasted into the S4
# results of the spec (and ADR-0006's notes).
#   tests/visual/overview-cost.sh [SECONDS=30]
# Run as a BARE command with a relative path, on the reference machine only; the nested session it starts is torn down on exit.
# Exit status 1 when a profile cannot be measured (no shell or compositor pid) or the balanced profile costs 5 % or more of
# a core with the Overview open (the figure the spec's default rests on).
source "$(dirname "$0")/lib.sh"
set +e

secs=${1:-30}
[[ $secs =~ ^[1-9][0-9]*$ ]] || { echo "usage: overview-cost.sh [SECONDS]" >&2; exit 2; }
out=$VS_STATE/overview-cost
was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_ipc overview close >/dev/null 2>&1 || true; vs_kill_clients || true; }
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*

ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat" 2>/dev/null; }
rss_mb() { awk '/^VmRSS:/ { printf "%.0f", $2 / 1024 }' "/proc/$1/status" 2>/dev/null; }
hypr_pid() { cat "$VS_DEV/nested.pid" 2>/dev/null; }
shell_pid() { cat "$VS_DEV/shell.pid" 2>/dev/null; }
set_profile() {
  local f=$VS_DEV/config/grassfield/grassfield.json tmp
  mkdir -p "$(dirname "$f")"
  [[ -s $f ]] || echo '{}' >"$f"
  tmp=$(mktemp "$f.XXXXXX") && jq --arg p "$1" '.material.profile = $p' "$f" >"$tmp" && mv "$tmp" "$f"
}
# measure LABEL: one markdown row, CPU % of one core of the shell and of Hyprland over $secs, and their RSS at the end.
balanced_open=""
measure() {
  local sp hp s0 s1 h0 h1 t0 t1 hz line s h
  sp=$(shell_pid)
  hp=$(hypr_pid)
  [[ -n $sp && -n $hp ]] || { echo "| $1 | no pid | no pid | | |"; return 1; }
  hz=$(getconf CLK_TCK)
  s0=$(ticks "$sp"); h0=$(ticks "$hp"); t0=$(date +%s%N)
  sleep "$secs"
  s1=$(ticks "$sp"); h1=$(ticks "$hp"); t1=$(date +%s%N)
  s=$(awk -v a="$s0" -v b="$s1" -v dt=$((t1 - t0)) -v hz="$hz" 'BEGIN { printf "%.1f", 100 * (b - a) / hz / (dt / 1e9) }')
  h=$(awk -v a="$h0" -v b="$h1" -v dt=$((t1 - t0)) -v hz="$hz" 'BEGIN { printf "%.1f", 100 * (b - a) / hz / (dt / 1e9) }')
  line="| $1 | $s % | $(rss_mb "$sp") MB | $h % | $(rss_mb "$hp") MB |"
  echo "$line" | tee -a "$out/table.md"
  [[ $1 == "open, balanced"* ]] && balanced_open=$s
  return 0
}

vs_session en
vs_reset dark 0.25
for i in 1 2 3 4 5 6 7 8 9; do
  vs_foot "Terminal $i" 70x20
  vs_wait_clients "$i"
done
vs_park
sleep 3

fail=0
{
  echo "S4: 9 foot windows on $VS_OUTPUT, ${secs} s per row, CPU = % of one core from /proc/<pid>/stat (indication, nested)"
  echo
  echo "| State | grassfield-shell CPU | grassfield-shell RSS | nested Hyprland CPU | nested Hyprland RSS |"
  echo "|---|---|---|---|---|"
} | tee "$out/table.md"
measure "closed" || fail=1
for p in full balanced reduced; do
  set_profile "$p"
  sleep 2
  vs_ipc overview open >/dev/null
  sleep 3
  measure "open, $p" || fail=1
  vs_ipc overview close >/dev/null
  sleep 1.5
done
echo
if [[ -n $balanced_open ]] && awk "BEGIN { exit !($balanced_open >= 5) }"; then
  echo "FAIL balanced with the Overview open costs $balanced_open % of a core (limit 5 %)"
  fail=1
else
  echo "PASS balanced with the Overview open costs ${balanced_open:-?} % of a core (limit 5 %)"
fi
exit "$fail"
