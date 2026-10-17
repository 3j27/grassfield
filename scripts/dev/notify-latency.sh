#!/usr/bin/env bash
# Notify round-trip latency of the nested shell's notification server (private bus only).
# Usage: scripts/dev/notify-latency.sh [COUNT=60] [LIMIT_MS=50]
# Sends COUNT notifications (each with a body, one default and one extra action) and prints the
# D-Bus Notify round-trip time of each in ms, then min/median/p95/max. Exit 1 if the median of
# the last 10 sends (history full) exceeds LIMIT_MS. The time includes gdbus start-up (~10 ms).
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
count=${1:-60}
limit=${2:-50}
[[ -s $dev/bus.address ]] || { echo "notify-latency: no private bus (GRASSFIELD_PRIVATE_BUS=1 scripts/dev/nested-up.sh)" >&2; exit 1; }
export DBUS_SESSION_BUS_ADDRESS
DBUS_SESSION_BUS_ADDRESS=$(cat "$dev/bus.address")

times=()
for i in $(seq 1 "$count"); do
  t0=$(date +%s%N)
  gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "latency" 0 "" "Latency $i" "Body <b>$i</b> of the latency test" \
    '["default","Open","ok","OK"]' '{}' 20000 >/dev/null
  t1=$(date +%s%N)
  times+=($(((t1 - t0) / 1000000)))
done

printf '%s\n' "${times[@]}" | tr '\n' ' '
echo
sorted=$(printf '%s\n' "${times[@]}" | sort -n)
n=${#times[@]}
echo "n=$n min=$(sed -n 1p <<<"$sorted") median=$(sed -n "$(((n + 1) / 2))p" <<<"$sorted") p95=$(sed -n "$((n * 95 / 100 > 0 ? n * 95 / 100 : 1))p" <<<"$sorted") max=$(sed -n "${n}p" <<<"$sorted") ms"
last=$(printf '%s\n' "${times[@]: -10}" | sort -n | sed -n 5p)
echo "median of last 10 = ${last} ms (limit ${limit})"
[[ $last -le $limit ]]
