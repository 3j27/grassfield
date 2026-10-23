#!/usr/bin/env bash
# Offline test of the soak harness logic (GF-006): the verdict of an action type, the RSS slope, and the window
# geometry filter the soak and the input test aim with. Needs jq and awk only; no compositor.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=../compositor/soak_lib.sh
. "$root/tests/compositor/soak_lib.sh"
# shellcheck source=../compositor/window_geometry.sh
. "$root/tests/compositor/window_geometry.sh"

fails=0
expect() { # <name> <got> <want>
  if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}

# 0 attempts or 0 effective actions is a harness error (the audit's "0 minimize pairs" run), never a pass.
expect "no attempt" "$(soak_action_verdict 0 0 50)" harness
expect "425 attempts, 0 effective (the audited run)" "$(soak_action_verdict 425 0 50)" harness
expect "below the minimum share" "$(soak_action_verdict 100 49 50)" fail
expect "at the minimum share" "$(soak_action_verdict 100 50 50)" ok
expect "all effective" "$(soak_action_verdict 7 7 50)" ok

# 20 MB/h exactly: one sample per 10 min, +20/6 MB each.
samples=$(mktemp)
trap 'rm -f "$samples"' EXIT
for i in $(seq 0 12); do echo "$((1000 + i * 600)) $(((100 * 1024) + i * 20 * 1024 / 6))"; done >"$samples"
expect "slope of a linear growth" "$(soak_slope_mb_h "$samples" 0)" 20.00
expect "slope after a warm-up" "$(soak_slope_mb_h "$samples" 1200)" 20.00
for i in $(seq 0 12); do echo "$((1000 + i * 600)) $((100 * 1024))"; done >"$samples"
expect "flat RSS" "$(soak_slope_mb_h "$samples" 0)" 0.00
head -n 3 "$samples" >"$samples.short"
expect "too few samples" "$(soak_slope_mb_h "$samples.short" 0)" n/a
rm -f "$samples.short"
expect "bound respected" "$(soak_rss_verdict 9.99 10)" ok
expect "bound exceeded" "$(soak_rss_verdict 10.5 10)" fail
expect "short run is reported as unjudged" "$(soak_rss_verdict n/a 10)" unjudged

# Window geometry from `hyprctl -j clients`: output-relative, the right pid, mapped, visible, on the output.
clients='[
 {"pid": 11, "mapped": true, "hidden": false, "monitor": 1, "at": [1610, 302], "size": [700, 500], "workspace": {"name": "1"}},
 {"pid": 12, "mapped": true, "hidden": false, "monitor": 0, "at": [610, 302], "size": [700, 500], "workspace": {"name": "1"}},
 {"pid": 13, "mapped": true, "hidden": true, "monitor": 1, "at": [0, 0], "size": [10, 10], "workspace": {"name": "special:minimized"}},
 {"pid": 14, "mapped": false, "hidden": false, "monitor": 1, "at": [0, 0], "size": [10, 10], "workspace": {"name": "1"}}]'
expect "geometry on the second output" "$(gf_geom_filter 11 1 1000 0 <<<"$clients")" "610 302 700 500"
expect "window on another output" "$(gf_geom_filter 12 1 1000 0 <<<"$clients")" ""
expect "minimized window" "$(gf_geom_filter 13 1 1000 0 <<<"$clients")" ""
expect "unmapped window" "$(gf_geom_filter 14 1 1000 0 <<<"$clients")" ""
expect "unknown pid" "$(gf_geom_filter 99 1 1000 0 <<<"$clients")" ""

gf_geom_moved "100 80 700 500" "100 80 705 500" && moved=yes || moved=no
expect "5 px is not a move" "$moved" no
gf_geom_moved "100 80 700 500" "400 300 700 500" && moved=yes || moved=no
expect "a drag is a move" "$moved" yes
gf_geom_moved "100 80 700 500" "0 20 1920 1000" && moved=yes || moved=no
expect "a zoom is a move" "$moved" yes

# Title bar targets follow the window, not a constant.
GF_TB_MID=14 GF_TB_CLOSE_X=18 GF_TB_MIN_X=38 GF_TB_ZOOM_X=58
expect "bar point" "$(gf_bar_point 610 302 700 500)" "960 288"
expect "close button" "$(gf_button_point close 100 80 700 500)" "118 66"
expect "minimize button" "$(gf_button_point min 100 80 700 500)" "138 66"
expect "zoom button" "$(gf_button_point zoom 100 80 700 500)" "158 66"

if ((fails == 0)); then echo "PASS soak_lib"; else echo "FAIL soak_lib: $fails"; exit 1; fi
