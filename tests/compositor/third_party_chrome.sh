#!/usr/bin/env bash
# L1 nested scenario (GF-056; ADR-0015 amendment 2026-10-25): a third-party app that draws its own window controls gets
# exactly one set, its own, while a window that draws none keeps the plugin's titlebar. macOS: a window has one set of
# traffic lights; an app with its own title bar gets no second bar from the system.
#
# Usage: tests/compositor/third_party_chrome.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin and Evince (/usr/bin/evince, a GTK header-bar app on
# the session's third-party list, class org.gnome.Evince). hyprctl only through scripts/nestctl (read-only, plus window
# moves for the capture); captures with grim; clients through scripts/dev/isolated.sh with the nested socket only.
#
# Assertions:
#   1  SESSION  Evince carries the Hyprland tag grassfield-client-chrome (rule gf-client-chrome-third-party); foot not
#   2  PLUGIN   no plugin strip above Evince, one above foot (the strip measurement of client_chrome.sh); the capture of
#               GF-REF is kept for the visual check (one set of controls on Evince: its header bar's)
#   3  SESSION  Evince's own zoom works: a double-click on its header bar maximizes it (fullscreen=1, exempt from the
#               maximize suppression) and a second one restores it
#   4  report   foot asked for client-side decorations (csd.preferred=client, not on the list): what Hyprland answered,
#               shown by the same capture (two bars when foot draws its own; the plugin's alone when Hyprland answers
#               server-side, as 0.56.2 did on 2026-10-25: a client that negotiates never draws a second set here)
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log and captures: .dev/third-party-chrome/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${TPC_OUTPUT:-GF-REF}

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "third_party_chrome: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "third_party_chrome: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
command -v evince >/dev/null || { echo "third_party_chrome: Evince is not installed" >&2; exit 2; }

work=$dev/third-party-chrome
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }

read -r mon_x mon_y mon_w mon_h < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "third_party_chrome: output $out not found" >&2; exit 2; }
ctl -j plugin list | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null \
  || { echo "third_party_chrome: the plugin is not loaded" >&2; exit 2; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class == \$c) | $2" | head -1; }
geom() {
  ctl clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class == $c) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen)"' | head -1
}
mapped() { [[ -n $(client "$1" .address) ]]; }
wait_mapped() { local i; for i in $(seq 1 60); do mapped "$1" && return 0; sleep 0.25; done; return 1; }
move_to() { # <class> <x> <y> (output px)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$(client "$1" .address)' })" >>"$log" 2>&1
}
# The plugin strip above a surface (as in client_chrome.sh): 1 when two rows of the strip have the strip's colour at five
# points across the window, 0 otherwise. <png> <x> <y> <w> (output px).
strip_above() {
  local i r hexes=()
  for r in 4 $((GF_TB_HEIGHT - 4)); do
    for i in 20 35 50 65 80; do
      hexes+=("$(magick "$1" -format "%[hex:p{$(($2 + $4 * i / 100)),$(($3 - r))}]" info: 2>/dev/null | cut -c1-6)")
    done
  done
  python3 -I - "$(jq -r '.titlebar.backgroundDark.value' "$root/ui/tokens/tokens.json")" \
    "$(jq -r '.titlebar.backgroundLight.value' "$root/ui/tokens/tokens.json")" "${hexes[@]}" <<'PY'
import sys
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) if len(h) >= 6 else None
tokens = [rgb(t) for t in sys.argv[1:3]]
points = [rgb(h) for h in sys.argv[3:]]
def near(a, b):
    return a is not None and b is not None and max(abs(x - y) for x, y in zip(a, b)) <= 8
print(1 if points and all(any(near(p, t) for t in tokens) for p in points) else 0)
PY
}

say "third_party_chrome: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}"
pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 50
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name third-party-chrome -- foot --window-size-pixels=560x300 >>"$log" 2>&1 </dev/null &
pids+=($!)
wait_mapped foot || { say "setup error: foot did not map"; exit 2; }
WAYLAND_DISPLAY=$sock GDK_BACKEND=wayland setsid "$root/scripts/dev/isolated.sh" --name third-party-chrome -- evince >>"$log" 2>&1 </dev/null &
pids+=($!)
wait_mapped org.gnome.Evince || { say "setup error: Evince did not map as class org.gnome.Evince ($(ctl clients -j | jq -c '[.[].class]'))"; exit 2; }
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name third-party-chrome -- foot --app-id gf-csd-foot \
  -o csd.preferred=client --window-size-pixels=480x220 >>"$log" 2>&1 </dev/null &
pids+=($!)
wait_mapped gf-csd-foot || say "  (the csd foot did not map: report 4 skipped)"
sleep 1.5

say "1 tags"
etags=$(client org.gnome.Evince '.tags | join(",")')
ftags=$(client foot '.tags | join(",")')
[[ $etags == *grassfield-client-chrome* && $ftags != *grassfield-client-chrome* ]]
check "Evince tagged, foot not (SESSION, gf-client-chrome-third-party)" $? "Evince '$etags', foot '$ftags'"

say "2 one set of controls: no plugin strip above Evince, one above foot"
read -r _ _ ew0 eh0 _ < <(geom org.gnome.Evince)
move_to foot 40 120
move_to org.gnome.Evince $((mon_w - ew0 - 40)) $((mon_h - eh0 - 60))
mapped gf-csd-foot && move_to gf-csd-foot 40 $((mon_h - 300))
sleep 1
read -r ex ey ew eh _ < <(geom org.gnome.Evince)
read -r fx fy fw fh _ < <(geom foot)
WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/one-set.png" 2>>"$log"
e_strip=$(strip_above "$work/one-set.png" "$ex" "$ey" "$ew")
f_strip=$(strip_above "$work/one-set.png" "$fx" "$fy" "$fw")
[[ $e_strip == 0 && $f_strip == 1 ]]
check "no strip on Evince, strip on foot (PLUGIN P1 through the tag)" $? \
  "above Evince ${ew}x${eh} at ($ex,$ey): $e_strip (want 0); above foot at ($fx,$fy): $f_strip (want 1); capture $work/one-set.png"
if mapped gf-csd-foot; then
  read -r cx cy cw ch _ < <(geom gf-csd-foot)
  say "4 report: foot with csd.preferred=client (not on the list) ${cw}x${ch} at ($cx,$cy): plugin strip above it: $(strip_above "$work/one-set.png" "$cx" "$cy" "$cw") (the active window's strip may differ); whether foot drew its own bar too: see $work/one-set.png"
fi

say "3 Evince's own zoom (double-click on its header bar)"
hx=$((ex + ew / 2)); hy=$((ey + 22))
pointer abs "$hx" "$hy" sleep 80 click sleep 90 click sleep 900
read -r zx zy zw zh fs1 < <(geom org.gnome.Evince)
# The zoomed window sits under the menu bar: its own header bar is 22 px below its top edge.
pointer abs $((zx + zw / 2)) $((zy + 22)) sleep 80 click sleep 90 click sleep 900
read -r _ _ rw rh fs2 < <(geom org.gnome.Evince)
[[ $fs1 == 1 && $fs2 == 0 && $rw == "$ew" && $rh == "$eh" ]]
check "a double-click maximizes and restores (SESSION, maximize exemption)" $? \
  "after the first: fullscreen=$fs1 ${zw}x${zh}; after the second: fullscreen=$fs2 ${rw}x${rh} (was ${ew}x${eh})"

say "third_party_chrome: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
