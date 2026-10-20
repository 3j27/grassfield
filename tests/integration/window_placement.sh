#!/usr/bin/env bash
# Placement scenario (macOS model, config/hypr/grassfield/placement.lua): a browser's first window opens at least at the
# default size (72 % x 82 % of the output), centred; a client that arrives with a larger size keeps it; an application
# that is not a browser keeps the small size it asks for.
#
# Usage: tests/integration/window_placement.sh
# NESTED only: needs scripts/dev/nested-up.sh. Test clients are foot windows through scripts/dev/isolated.sh with the
# nested socket only (--app-id chromium stands in for a browser that committed a small window); hyprctl is read-only
# (scripts/nestctl -j clients). No shell runs in the nested session in this test, so the usable area is the whole output.
#
#   1 foot --app-id chromium, asks 500x350 (no stored geometry): grown to the default size, centred
#   2 foot --app-id chromium, asks 1500x900 (a size of its own, larger than the default): kept
#   3 foot --app-id gf-placement-probe, asks 500x350: kept (not a browser)
# Sizes are compared with a tolerance of 24 px (foot rounds to its cell grid).
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/window-placement/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${WP_OUTPUT:-GF-REF}
tol=24
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK

for tool in jq foot; do
  command -v "$tool" >/dev/null || { echo "window_placement: $tool not installed" >&2; exit 2; }
done

work=$dev/window-placement
mkdir -p "$work"
stamp=$(date +%Y%m%d-%H%M%S)
log=$work/run-$stamp.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
clients() { timeout 5 "$root/scripts/nestctl" -j clients; }

read -r mon_x mon_y mon_w mon_h < <(timeout 5 "$root/scripts/nestctl" -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "window_placement: output $out not found" >&2; exit 2; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

open_foot() { # <app-id> <title> <WxH>
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" --title "$2" -W "$3" >/dev/null 2>&1 </dev/null &
  pids+=("$!")
  sleep 2
}
geom() { # <title> -> "x y w h" relative to the output
  clients | jq -r --arg t "$1" --argjson mx "$mon_x" --argjson my "$mon_y" '.[] | select(.title == $t) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"'
}
near() { local d=$(($1 - $2)); ((d < 0)) && d=$((-d)); ((d <= tol)); }

fail=0
check() { # <label> <0|1> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}
centred() { # <x> <y> <w> <h>: window middle within the tolerance of the output middle (the titlebar shifts y a little)
  near $(($1 + $3 / 2)) $((mon_w / 2)) && near $(($2 + $4 / 2)) $((mon_h / 2 + 20))
}

want_w=$((mon_w * 72 / 100))
want_h=$((mon_h * 82 / 100))
say "window_placement: output $out ${mon_w}x${mon_h}, default ${want_w}x${want_h}"
pointer abs $((mon_w / 2)) $((mon_h - 150)) sleep 50 # windows open on the output under the pointer

say "1 browser class, asks 500x350"
open_foot chromium gf-place-small 500x350
read -r x y w h < <(geom gf-place-small)
[[ -n ${w:-} ]] || { say "setup error: window missing"; exit 2; }
check "grown to the default size" "$({ near "$w" "$want_w" && near "$h" "$want_h"; } && echo 0 || echo 1)" "got ${w}x${h} at ($x,$y), want ${want_w}x${want_h}"
check "centred" "$(centred "$x" "$y" "$w" "$h" && echo 0 || echo 1)" "middle ($((x + w / 2)),$((y + h / 2))) of ${mon_w}x${mon_h}"

say "2 browser class, asks 1500x900"
open_foot chromium gf-place-large 1500x900
read -r x y w h < <(geom gf-place-large)
[[ -n ${w:-} ]] || { say "setup error: window missing"; exit 2; }
check "own larger size kept" "$({ near "$w" 1500 && near "$h" 900; } && echo 0 || echo 1)" "got ${w}x${h}, asked 1500x900"

say "3 other class, asks 500x350"
open_foot gf-placement-probe gf-place-other 500x350
read -r x y w h < <(geom gf-place-other)
[[ -n ${w:-} ]] || { say "setup error: window missing"; exit 2; }
check "own size kept" "$({ near "$w" 500 && near "$h" 350; } && echo 0 || echo 1)" "got ${w}x${h}, asked 500x350"

if ((fail)); then say "window_placement: FAIL (log $log)"; exit 1; fi
say "window_placement: PASS (log $log)"
