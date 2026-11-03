#!/usr/bin/env bash
# Window edge and shadow (ADR-0024 C-3 and C-4, note 2026-11-03): a Grassfield Settings window on flat wallpapers,
# captured on GF-REF; the darkening along the middle of each side (tests/compositor/edge_measure.py), compared with
# Hyprland's shadow model at the values of config/hypr/grassfield/looknfeel.lua, with the macOS 27 target and with the edge
# tokens the shell pushes. None of it is the plugin's: run it with and without (nested-up.sh --no-plugin).
#
# Usage: tests/compositor/window_edge.sh
# NESTED only: needs scripts/dev/nested-up.sh (GF-REF at any scale; the target is measured in points). Clients go through
# scripts/dev/isolated.sh with the nested socket only, hyprctl is read-only (scripts/nestctl -j) and the window moves go
# through scripts/nestctl. The dev settings file (appearance, wallpaper) is changed and restored at exit.
#
# Scenarios: the light and the dark appearance, each over a flat light (#E6E6E6) and a mid-tone (#808080) wallpaper, the
# Settings window active, then inactive (a foot window focused in a corner).
# Checks (light wallpaper; device pixels along the middle of each side):
#   1 the rendered shadow is the configured one: past the contact pixel, within 0.03 of Hyprland's model at every
#     distance on the left, right, top and bottom, active and inactive (the inactive colour's alpha)
#   2 the shadow against the macOS 27 target, active, past the contact pixel: within 0.06 on the sides, 0.03 on the top
#     and 0.08 on the bottom (one offset box holds a plateau under the window where macOS 27 slopes, ADR-0024 note
#     2026-11-03)
#   3 the contact edge, the border's one device pixel: its darkening over the shadow next to it (1 - (1 - contact) /
#     (1 - next)) within 0.03 of the tokens window.edge{Active,Inactive}Opacity{Light,Dark} (black), on every side
#   4 no inner rim in either appearance: the first device pixel inside the window within 2 levels of the pixel next to it
#     (a rim is a step; Hyprland's inner glow stays off, the dark appearance's rim is deferred to the plugin)
# The dark appearance's edge is also logged in levels (window, contact pixel, the shadow next to it) for the record.
# Captures, 3x crops of the left edge and the bottom-left corner, profiles, report and plot: .dev/window-edge/run-<time>/.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${EDGE_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG

for tool in jq foot grim magick python3; do
  command -v "$tool" >/dev/null || { echo "window_edge: $tool not installed" >&2; exit 2; }
done
settings_bin=${EDGE_SETTINGS_BIN:-$dev/build/grassfield-settings}
[[ -x $settings_bin ]] || { echo "window_edge: $settings_bin not built (apps/settings/build-direct.sh)" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
run=$dev/window-edge/run-$stamp
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
clients() { timeout 5 "$root/scripts/nestctl" -j clients; }
dispatch() { timeout 5 "$root/scripts/nestctl" dispatch "$1" >>"$log" 2>&1; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

mon_w=""
for _ in $(seq 1 40); do
  read -r mon_x mon_y mon_w mon_h scale < <(timeout 5 "$root/scripts/nestctl" -j monitors \
    | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.scale)"')
  [[ -n ${mon_w:-} ]] && break
  sleep 0.25
done
[[ -n ${mon_w:-} ]] || { echo "window_edge: output $out not found (waited 10 s)" >&2; exit 2; }
lw=$(awk -v w="$mon_w" -v s="$scale" 'BEGIN { printf "%d", w / s }')
lh=$(awk -v h="$mon_h" -v s="$scale" 'BEGIN { printf "%d", h / s }')

# The configured shadow (looknfeel.lua): range, render_power, offset y, the active and inactive colour's alpha.
lnf=$root/config/hypr/grassfield/looknfeel.lua
shadow_block=$(sed -n '/^    shadow = {/,/^    },/p' "$lnf")
cfg() { sed -n "s/^ *$1 = \\([0-9.]*\\),.*/\\1/p" <<<"$shadow_block" | head -n 1; }
s_range=$(cfg range) s_power=$(cfg render_power)
s_off=$(sed -n 's/^ *offset = { *[-0-9.]*, *\([-0-9.]*\) *},.*/\1/p' <<<"$shadow_block")
hex_alpha() { awk -v h="$((16#$1))" 'BEGIN { printf "%.4f", h / 255 }'; }
s_alpha=$(hex_alpha "$(sed -n 's/^ *color = "rgba(......\(..\))",.*/\1/p' <<<"$shadow_block")")
s_alpha_in=$(hex_alpha "$(sed -n 's/^ *color_inactive = "rgba(......\(..\))",.*/\1/p' <<<"$shadow_block")")
[[ -n $s_range && -n $s_power && -n $s_off ]] || { echo "window_edge: shadow values not found in $lnf" >&2; exit 2; }
say "window_edge: $out ${mon_w}x${mon_h} scale $scale (${lw}x${lh} pt); shadow range $s_range power $s_power alpha $s_alpha (inactive $s_alpha_in) offset $s_off"

pids=()
settings_file=$dev/config/grassfield.json
settings_backup=$run/settings.backup
had_settings=0
[[ -f $settings_file ]] && { cp "$settings_file" "$settings_backup"; had_settings=1; }
cleanup() {
  local p
  for p in "${pids[@]}"; do dev_may_signal "$p" && kill "$p" 2>/dev/null; done
  if ((had_settings)); then cp "$settings_backup" "$settings_file"; else rm -f "$settings_file"; fi
}
trap cleanup EXIT

fail=0
check() { # <label> <0 = ok> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

look_now="" # the appearance the shell was last seen pushing
set_look() { # <dark|light> <#rrggbb wallpaper>: rewrite the dev settings file, wait for the shell's edge push and the crossfade
  local base=$root/config/defaults/grassfield.json n
  ((had_settings)) && base=$settings_backup
  mkdir -p "$dev/config"
  n=$(grep -c "push window edge ($1)" "$dev/shell.log" 2>/dev/null)
  jq --arg a "$1" --arg c "$2" '.appearance = $a | .wallpaper.source = "color" | .wallpaper.color = $c' "$base" \
    >"$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  if [[ $1 != "$look_now" ]]; then # a shell that has just started can take seconds to read the file (load)
    for _ in $(seq 1 150); do
      (($(grep -c "push window edge ($1)" "$dev/shell.log" 2>/dev/null) > ${n:-0})) && { look_now=$1; break; }
      sleep 0.1
    done
    [[ $look_now == "$1" ]] || say "  no 'push window edge ($1)' in the shell log after 15 s"
  fi
  sleep 1.5 # the app's own appearance change, the debounced push, a frame; capture() waits for the wallpaper itself
}

# New windows open on the output under the pointer.
pointer abs 8 $((lh / 2)) sleep 200

# Settings, 640 x 400 pt, in the middle of the space between the menu bar and the Dock.
bus=""
[[ -f $dev/bus.address ]] && bus=$(<"$dev/bus.address")
"$root/scripts/dev/isolated.sh" --name window-edge --config-home "$dev/config" --state-home "$dev/state" -- \
  env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 \
  QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" GRASSFIELD_LANG=en \
  HYPRLAND_INSTANCE_SIGNATURE="$sig" "$settings_bin" >>"$log" 2>&1 </dev/null &
pids+=("$!")
addr=""
for _ in $(seq 1 60); do
  addr=$(clients | jq -r '.[] | select(.class == "org.grassfield.Settings") | .address' | head -n 1)
  [[ -n $addr ]] && break
  sleep 0.25
done
[[ -n $addr ]] || { say "window_edge: setup error: no Settings window"; exit 2; }
ww=640 wh=400
wx=$(((lw - ww) / 2)) wy=$((24 + (lh - 24 - 70 - wh) / 2))
sleep 1
dispatch "hl.dsp.window.resize({ x = $ww, y = $wh, exact = true, window = 'address:$addr' })"
dispatch "hl.dsp.window.move({ x = $((mon_x + wx)), y = $((mon_y + wy)), window = 'address:$addr' })"
sleep 0.8
read -r gx gy gw gh < <(clients | jq -r --arg a "$addr" --argjson mx "$mon_x" --argjson my "$mon_y" \
  '.[] | select(.address == $a) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"')
say "Settings ${gw}x${gh} at ($gx,$gy) pt"

# A foot window in the top-left corner, clear of the measured lines and of their shadow: focusing it makes Settings inactive.
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name window-edge foot --title gf-edge-other -w 300x160 \
  -o colors-dark.alpha=1 -o colors-light.alpha=1 sh -c 'printf "\033[?25l"; exec sleep 900' >/dev/null 2>&1 </dev/null &
pids+=("$!")
faddr=""
for _ in $(seq 1 40); do
  faddr=$(clients | jq -r '.[] | select(.title == "gf-edge-other") | .address' | head -n 1)
  [[ -n $faddr ]] && break
  sleep 0.25
done
[[ -n $faddr ]] || { say "window_edge: setup error: no foot window"; exit 2; }
dispatch "hl.dsp.window.move({ x = $((mon_x + 40)), y = $((mon_y + 60)), window = 'address:$faddr' })"
pointer abs 8 $((lh / 2)) sleep 200

capture() { # <name> <wallpaper hex>: once the wallpaper 150 px left of the window is that colour (the crossfade done; 10 s)
  local try bx by
  bx=$(awk -v x="$gx" -v s="$scale" 'BEGIN { printf "%d", x * s - 150 }') by=$(awk -v y="$gy" -v h="$gh" -v s="$scale" 'BEGIN { printf "%d", (y + h / 2) * s }')
  for try in $(seq 1 20); do
    WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/$1.ppm" 2>>"$log"
    python3 -I "$root/tests/compositor/edge_measure.py" background "$run/$1.ppm" "$bx" "$by" "$2" 2>>"$log" && break
    ((try == 20)) && say "  $1: the wallpaper is not $2 after 10 s (measured anyway)"
    sleep 0.5
  done
  magick "$run/$1.ppm" "$run/$1.png"
  python3 -I "$root/tests/compositor/edge_measure.py" profile "$run/$1.ppm" "$scale" "$gx" "$gy" "$gw" "$gh" "$2" >"$run/$1.json"
  local px py pw ph
  px=$(awk -v x="$gx" -v s="$scale" 'BEGIN { printf "%d", x * s }') py=$(awk -v y="$gy" -v s="$scale" 'BEGIN { printf "%d", y * s }')
  pw=$(awk -v w="$gw" -v s="$scale" 'BEGIN { printf "%d", w * s }') ph=$(awk -v h="$gh" -v s="$scale" 'BEGIN { printf "%d", h * s }')
  magick "$run/$1.ppm" -crop "60x40+$((px - 40))+$((py + ph / 2 - 20))" +repage -filter point -resize 300% "$run/$1-left-3x.png"
  magick "$run/$1.ppm" -crop "160x140+$((px - 60))+$((py + ph - 40))" +repage -filter point -resize 300% "$run/$1-corner-3x.png"
}

for look in light dark; do
  for wall in E6E6E6 808080; do
    set_look "$look" "#$wall"
    dispatch "hl.dsp.focus({ window = 'address:$addr' })"
    sleep 0.6
    capture "$look-$wall-active" "#$wall"
    dispatch "hl.dsp.focus({ window = 'address:$faddr' })"
    sleep 0.6
    capture "$look-$wall-inactive" "#$wall"
    say "captured $look over #$wall, active and inactive"
  done
done

python3 -I "$root/tests/compositor/edge_measure.py" report "$run/report-active.txt" "$run/profile-active.svg" \
  "$s_range" "$s_power" "$s_alpha" "$s_off" "$run"/{light,dark}-{E6E6E6,808080}-active.json 2>>"$log"
python3 -I "$root/tests/compositor/edge_measure.py" report "$run/report-inactive.txt" "$run/profile-inactive.svg" \
  "$s_range" "$s_power" "$s_alpha_in" "$s_off" "$run"/{light,dark}-{E6E6E6,808080}-inactive.json 2>>"$log"
for f in profile-active profile-inactive; do rsvg-convert "$run/$f.svg" -o "$run/$f.png" 2>>"$log"; done
declare -A r=()
while IFS='=' read -r k v; do r[$k]=${v%% *}; done < <(cat "$run/report-active.txt" "$run/report-inactive.txt")

# 1 the rendered shadow is the configured one
for state in active inactive; do
  for side in left right top bottom; do
    v=${r[light-E6E6E6-$state.$side.model_max_dev]:-9}
    awk -v v="$v" 'BEGIN { exit !(v <= 0.03) }'
    check "1 light wallpaper, $state, $side: render = model" $? "largest difference $v (at most 0.03)"
  done
done

# 2 against the macOS 27 target
for side in left right top bottom; do
  case $side in top) lim=0.03 ;; bottom) lim=0.08 ;; *) lim=0.06 ;; esac
  v=${r[light-E6E6E6-active.$side.mac27_max_dev]:-9}
  awk -v v="$v" -v l="$lim" 'BEGIN { exit !(v <= l) }'
  check "2 light wallpaper, active, $side: shadow against macOS 27" $? "largest difference $v (at most $lim; first 16 pt ${r[light-E6E6E6-active.$side.mac27_max_dev_16pt]:-?})"
done

# 3 the contact edge
token() { jq -r --arg k "$1" '.window[$k].value' "$root/ui/tokens/tokens.json"; }
contact_over() { # <json> <side>: the contact pixel's darkening over the shadow next to it
  jq -r --arg s "$2" '.sides[$s].alpha | "\(.[0]) \(.[1])"' "$1" | awk '{ printf "%.3f", 1 - (1 - $1) / (1 - $2) }'
}
for look in light dark; do
  L=${look^}
  for state in active inactive; do
    want=$(token "edge${state^}Opacity$L")
    for side in left right top bottom; do
      v=$(contact_over "$run/$look-E6E6E6-$state.json" "$side")
      awk -v v="$v" -v w="$want" 'BEGIN { d = v - w; if (d < 0) d = -d; exit !(d <= 0.03) }'
      check "3 $look, $state, $side: contact edge" $? "darkening over the shadow $v (token $want +-0.03)"
    done
  done
done

# 4 no inner rim
rim_levels() { # <json> <side>: the first pixel inside minus the next one in, in levels (mean of the channels; a rim is a step)
  jq -r --arg s "$2" '.sides[$s].rgb | ((.[7] | add) - (.[6] | add)) / 3' "$1" | awk '{ printf "%.1f", $1 }'
}
levels() { # <json> <side>: window, contact pixel and the next one outside, in levels (mean of the channels)
  jq -r --arg s "$2" '.sides[$s].rgb | [.[3], .[8], .[9]] | map(add / 3 | floor) | "window \(.[0]), contact \(.[1]), shadow \(.[2])"' "$1"
}
for look in light dark; do
  for state in active inactive; do
    for side in left right top bottom; do
      v=$(rim_levels "$run/$look-E6E6E6-$state.json" "$side")
      awk -v v="$v" 'BEGIN { if (v < 0) v = -v; exit !(v <= 2) }'
      check "4 $look, $state, $side: no inner rim" $? "$v levels over the window (at most 2)"
    done
  done
done
for wall in E6E6E6 808080; do
  for state in active inactive; do
    say "  dark edge over #$wall, $state: left $(levels "$run/dark-$wall-$state.json" left); bottom $(levels "$run/dark-$wall-$state.json" bottom)"
  done
done

say "captures, crops, profiles and plots: $run"
if ((fail)); then say "window_edge: FAIL"; exit 1; fi
say "window_edge: PASS"
exit 0
