#!/usr/bin/env bash
# Gate P3: frame pacing of the shell while a surface is exercised in the NESTED session (reference machine; BARE command,
# it starts or reuses the nested session through tests/visual/lib.sh and never touches the owner's session).
#
#   scripts/gates/frame-pacing.sh [dock|overview|apps|all] [N]       N = repetitions, default 20 (the gate's count)
#     dock      N sweeps of the pointer across the Dock with magnification on (reduce-motion off)
#     overview  N Overview open/close cycles
#     apps      N Apps panel open/close cycles
#
# The shell runs with GRASSFIELD_RENDER_TIMING=1; the "frame rendered in R ms" lines of each exercise are cut from
# .dev/shell.log into .dev/gates/frame-pacing/<surface>.<timestamp>.log and judged by scripts/gates/frame_pacing.py:
# >= 95 % of the frames < 16.7 ms and at least 100 frames. The gate asks for the Balanced power profile: the profile in
# force is printed (powerprofilesctl get), it is not changed.
# Exit: 0 every surface PASS, 1 any FAIL, 2 any INCONCLUSIVE (too few frames) or an environment error.
source "$(dirname "$0")/../../tests/visual/lib.sh"

what=${1:-all}
n=${2:-20}
[[ $what == dock || $what == overview || $what == apps || $what == all ]] || { echo "usage: frame-pacing.sh [dock|overview|apps|all] [N]" >&2; exit 2; }
[[ $n =~ ^[1-9][0-9]*$ ]] || { echo "frame-pacing: N is a positive integer" >&2; exit 2; }
out=$VS_DEV/gates/frame-pacing
mkdir -p "$out"
stamp=$(date +%Y%m%d-%H%M%S)

echo "P3: power profile: $(powerprofilesctl get 2>/dev/null || echo 'unknown (powerprofilesctl not available)'); commit $(git -C "$VS_ROOT" rev-parse --short HEAD)"
export GRASSFIELD_RENDER_TIMING=1
vs_session en
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null

run_surface() { # <surface> <function exercising it once>
  local surface=$1 fn=$2 m0 i
  m0=$(wc -l <"$VS_DEV/shell.log")
  for i in $(seq 1 "$n"); do "$fn"; done
  tail -n +"$((m0 + 1))" "$VS_DEV/shell.log" >"$out/$surface.$stamp.log"
  python3 -I "$VS_ROOT/scripts/gates/frame_pacing.py" --surface "$surface (n=$n)" "$out/$surface.$stamp.log"
}
dock_once() {
  local args=() x
  for x in $(seq 700 20 1220); do args+=(abs "$x" 1045 sleep 30); done
  vs_pointer "${args[@]}" abs 960 600 sleep 400 >/dev/null
}
overview_once() { vs_ipc overview open >/dev/null; vs_sleep 1.2; vs_ipc overview close >/dev/null; vs_sleep 1; }
apps_once() { vs_ipc apps open >/dev/null; vs_sleep 1.2; vs_ipc apps close >/dev/null; vs_sleep 1; }

rc=0
worst() { (($1 == 1)) && rc=1; (($1 == 2 && rc == 0)) && rc=2; return 0; }
vs_ipc dock magnify 1.6 true >/dev/null
vs_park
vs_sleep 1.5
if [[ $what == dock || $what == all ]]; then run_surface dock dock_once || worst $?; fi
if [[ $what == overview || $what == all ]]; then run_surface overview overview_once || worst $?; fi
if [[ $what == apps || $what == all ]]; then run_surface apps apps_once || worst $?; fi
vs_park
echo "P3: logs in $out (*.$stamp.log)"
exit "$rc"
