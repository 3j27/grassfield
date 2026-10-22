#!/usr/bin/env bash
# Memory of the shell over many icon-mode switches (ADR-0014): the mode cycles default, dark, clear, tinted through the settings file
# `count` times (default 300) with the Apps panel open, so every switch creates and destroys the effects of a hundred icons. The shell's
# resident memory (KiB, ps) is printed every 50 switches; it must not grow with the number of switches. NOT a regression scenario.
# Run it as a BARE command.
#
#   tests/visual/icon-modes-switch-memory.sh [count]
source "$(dirname "$0")/lib.sh"
COUNT=${1:-300}
rss() { ps -eo rss=,args= | awk -v p="qs -p $VS_ROOT/shell" 'index($0, p) { print $1; exit }'; }
modes=(default dark clear tinted)

vs_session
vs_reset
vs_ipc apps open >/dev/null
vs_sleep 1.5
echo "start: $(rss) KiB"
for i in $(seq 1 "$COUNT"); do
  printf '{"version":1,"appearance":"dark","lock":{"idleMinutes":0},"icons":{"folderColor":"theme","mode":"%s"}}\n' "${modes[$((i % 4))]}" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  sleep 0.4
  (( i % 50 == 0 )) && echo "after $i switches: $(rss) KiB"
done
vs_ipc apps close >/dev/null
vs_sleep 2
echo "end: $(rss) KiB"
