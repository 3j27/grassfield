#!/usr/bin/env bash
# The Apps panel opening 5 times per icon mode, repeated: render and GUI frame statistics of the shell during the openings (the
# Apps part of icon-modes-perf.sh, without Files). NOT a regression scenario: writes
# .dev/visual/icon-modes-apps-perf/<mode>.<run>.log and prints one line per mode and run (tests/visual/apps-frames.py).
# Run it as a BARE command.
#
#   tests/visual/icon-modes-apps-perf.sh [runs] ["default dark clear tinted"]
source "$(dirname "$0")/lib.sh"
RUNS=${1:-3}
KINDS=${2:-"default dark clear tinted"}
OUT=$VS_STATE/icon-modes-apps-perf
mkdir -p "$OUT"

export GRASSFIELD_RENDER_TIMING=1
vs_session
vs_reset
for run in $(seq 1 "$RUNS"); do
  for kind in $KINDS; do
    printf '{"version":1,"appearance":"dark","lock":{"idleMinutes":0},"icons":{"folderColor":"theme","mode":"%s"}}\n' "$kind" > "$VS_DEV/config/grassfield.json"
    vs_sleep 2
    m0=$(wc -l < "$VS_DEV/shell.log")
    for i in 1 2 3 4 5; do
      vs_ipc apps open >/dev/null
      vs_sleep 1.5
      vs_ipc apps close >/dev/null
      vs_sleep 1
    done
    tail -n +"$((m0 + 1))" "$VS_DEV/shell.log" > "$OUT/$kind.$run.log"
    python3 -I "$VS_HERE/apps-frames.py" "$OUT/$kind.$run.log"
  done
done
