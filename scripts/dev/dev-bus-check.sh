#!/usr/bin/env bash
# The dev session's private bus can start nothing of the machine (security counter-review of f9e24e1, LOW-2; ADR-0011): the
# only name it may list as activatable is the bus itself, org.freedesktop.DBus (scripts/dev/dev-bus.conf has no service
# folder). Asks the bus for its activatable names (org.freedesktop.DBus.ListActivatableNames, which starts nothing).
#
#   scripts/dev/dev-bus-check.sh <bus address>
#
# Exit 0: only org.freedesktop.DBus. 1: other names, one line each on stdout ("unexpected: <name>"). 2: the bus could not be
# asked or its answer not read (on stderr). scripts/dev/shell-run.sh refuses a bus that is not 0; tests/security/dev_bus.sh
# runs it on the bus started with dev-bus.conf and on controls.
set -uo pipefail
addr=${1:-}
[[ -n $addr && $# -eq 1 ]] || { echo "usage: dev-bus-check.sh <bus address>" >&2; exit 2; }
command -v gdbus >/dev/null || { echo "dev-bus-check: gdbus not found" >&2; exit 2; }
out=$(timeout 10 gdbus call --address "$addr" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.ListActivatableNames 2>&1) || { echo "dev-bus-check: the bus did not answer: $out" >&2; exit 2; }
# gdbus prints the reply as (['name', ...],); bus names never hold a quote, a comma or a space.
[[ $out =~ ^\(\[(\'[^\',\ ]+\'(,\ \'[^\',\ ]+\')*)?\],\)$ ]] || { echo "dev-bus-check: unexpected answer: $out" >&2; exit 2; }
names=$(grep -oE "'[^']+'" <<<"$out" | tr -d "'")
grep -qx 'org\.freedesktop\.DBus' <<<"$names" || { echo "dev-bus-check: the bus does not list itself: $out" >&2; exit 2; }
status=0
while IFS= read -r name; do
  [[ $name == org.freedesktop.DBus ]] && continue
  echo "unexpected: $name"
  status=1
done <<<"$names"
exit "$status"
