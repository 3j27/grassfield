#!/usr/bin/env bash
# Window chrome scenario (F2a, docs/testing/f1-reference-gaps.md "Window chrome"; spec FR2-FR4, FR4b): the plugin titlebar,
# its lights and hover glyphs and the window corner radii, measured on GF-REF captures (tests/compositor/chrome_measure.py).
#
# Usage: tests/compositor/chrome.sh
# NESTED only: needs scripts/dev/nested-up.sh. Pointer input goes through scripts/dev/pointer.sh, clients through
# scripts/dev/isolated.sh with the nested socket only, hyprctl is read-only (scripts/nestctl -j clients/monitors) and the
# dispatcher calls (window move, focus) go through scripts/nestctl. Expected geometry: tests/compositor/titlebar_geometry.sh.
#
#   1 foot A (a third-party window), active, pointer away: the three lights at their centres (+-0.75 px), 14 px across
#     (+-1), no glyph; the bar GF_TB_HEIGHT rows tall, flush with the window's left edge and the surface (no gap); its
#     top corners rounded like the window, radius 12 (inset of the first fill pixels on the corner's diagonal 3-5 px; a
#     square corner gives 0-1; measured on Hyprland 0.56.2: 4 at radius 12, 8 at radius 26); the lights coloured; bar and
#     content join square (no pixel of the content's cut top corners differs from the content next to them)
#   2 pointer in the gap between A's close and minimize lights (no light under the cursor image): glyphs on all three
#     lights (the whole group, macOS); pointer away again: no glyph
#   3 foot B opened and moved aside (A inactive): pointer on A's close light: lights coloured, glyphs on all three;
#     pointer away: grey lights (titlebarPalette inactiveLight), no glyph
#   3b the light appearance (audit UX-06; plugin feature "appearance"): the dev settings file says "light", the shell pushes
#     it; A's bar in the light palette (ui/tokens/tokens.json titlebar.backgroundLight), its lights in place, grey while
#     inactive, coloured once focused; back to dark: the dark bar again. The settings file is restored at exit.
#   4 Grassfield Settings (org.grassfield.Settings, when .dev/build/grassfield-settings exists): the same lights and bar,
#     radius 26 (the global default; corner inset 7-10 px), square join, glyphs with the pointer between its minimize
#     and zoom lights
# Without grassfield-compositor (C2: nested-up.sh --no-plugin, or scripts/nestctl plugin unload): no titlebar; only the
# radii are measured, at the surface's own corners (the Lua config alone sets them).
# Captures, 2x crops of the lights and the corners, measurements: .dev/chrome/run-<timestamp>/.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${CHROME_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG

for tool in jq foot grim magick python3; do
  command -v "$tool" >/dev/null || { echo "chrome: $tool not installed" >&2; exit 2; }
done

stamp=$(date +%Y%m%d-%H%M%S)
run=$dev/chrome/run-$stamp
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
clients() { timeout 5 "$root/scripts/nestctl" -j clients; }
dispatch() { timeout 5 "$root/scripts/nestctl" dispatch "$1" >>"$log" 2>&1; }
rounding_of() { timeout 5 "$root/scripts/nestctl" getprop "address:$1" rounding 2>>"$log" | head -n 1; } # effective window rule value

# In a fresh nested session GF-REF appears a moment after nested-up (Hyprland creates it from its start callback): wait
# for it, bounded (10 s), instead of failing.
mon_w=""
for _ in $(seq 1 40); do
  read -r mon_x mon_y mon_w mon_h < <(timeout 5 "$root/scripts/nestctl" -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
  [[ -n ${mon_w:-} ]] && break
  sleep 0.25
done
[[ -n ${mon_w:-} ]] || { echo "chrome: output $out not found (waited 10 s)" >&2; exit 2; }
plugin=0
HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -e '.features | index("decorations")' >/dev/null 2>&1 && plugin=1

pids=()
# The dev settings file of the nested shell (its GRASSFIELD_CONFIG_HOME), changed by step 3b and restored at exit.
settings_file=$dev/config/grassfield.json
settings_backup=$run/settings.backup
had_settings=0
[[ -f $settings_file ]] && { cp "$settings_file" "$settings_backup"; had_settings=1; }
set_appearance() { # <dark|light>: rewrite the dev settings file, wait for the shell's push to the plugin
  local base=$root/config/defaults/grassfield.json n
  ((had_settings)) && base=$settings_backup
  mkdir -p "$dev/config"
  n=$(grep -c "compositor setting appearance = $1" "$dev/shell.log" 2>/dev/null)
  jq --arg a "$1" '.appearance = $a' "$base" >"$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  for _ in $(seq 1 30); do
    (($(grep -c "compositor setting appearance = $1" "$dev/shell.log" 2>/dev/null) > ${n:-0})) && break
    sleep 0.1
  done
  sleep 0.5 # the dispatch, then a frame
}
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
park() { pointer abs 24 540 sleep 400; }

geom() { # <title> -> "x y w h address", x/y relative to the output
  clients | jq -r --arg t "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.title == $t) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.address)"' | head -n 1
}
geom_class() { # <class> -> "x y w h address"
  clients | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class == $c) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.address)"' | head -n 1
}

capture() { # <name>: GF-REF -> $run/<name>.ppm and .png
  WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/$1.ppm" 2>>"$log"
  magick "$run/$1.ppm" "$run/$1.png"
}

crops() { # <name> <x> <y> <w>: 2x crops (nearest neighbour) of the lights and of both top corners of the window at x,y (surface)
  local name=$1 x=$2 y=$3 w=$4 top
  top=$((y - (plugin ? GF_TB_HEIGHT : 0)))
  magick "$run/$name.ppm" -crop "92x$((GF_TB_HEIGHT + 16))+$((x - 8))+$((top - 8))" +repage -filter point -resize 200% "$run/$name-lights-2x.png"
  magick "$run/$name.ppm" -crop "48x$((GF_TB_HEIGHT + 24))+$((x - 8))+$((top - 8))" +repage -filter point -resize 400% "$run/$name-corner-left-4x.png"
  magick "$run/$name.ppm" -crop "48x$((GF_TB_HEIGHT + 24))+$((x + w - 40))+$((top - 8))" +repage -filter point -resize 400% "$run/$name-corner-right-4x.png"
}

# The palette the titlebar is measured against: the design tokens of the appearance shown (ui/tokens/tokens.json "titlebar").
token_hex() { jq -r --arg k "$1" '.titlebar[$k].value' "$root/ui/tokens/tokens.json" | tr -d '#'; }
palette_for() { # <dark|light>
  local a=${1^}
  palette_opts=("bar=$(token_hex "background$a")" "inactive=$(token_hex "inactiveButton$a")")
}
palette_for Dark
measure() { # <name> <x> <y> <w> [radius] -> key=value lines in $run/<name>.txt, loaded into m[...]
  local name=$1 x=$2 y=$3 w=$4 bar=$GF_TB_HEIGHT mid=$GF_TB_MID opts=("${palette_opts[@]}")
  [[ -n ${5:-} ]] && opts+=("radius=$5")
  # Without the plugin there is no titlebar: the corners are where the window's own content colour starts, sampled 16 px in
  # and 2 px down (inside the corner curve for radius 12 to 26, above the inset sidebar of Grassfield's apps).
  ((plugin)) || { bar=0 mid=0 opts+=("fill=$(magick "$run/$name.ppm" -format "%[hex:p{$((x + 16)),$((y + 2))}]" info: | cut -c1-6)"); }
  python3 -I "$root/tests/compositor/chrome_measure.py" "$run/$name.ppm" "$x" "$y" "$w" "$bar" "$GF_TB_CLOSE_X" "$GF_TB_MIN_X" "$GF_TB_ZOOM_X" "$mid" \
    "${opts[@]}" >"$run/$name.txt" 2>>"$log"
  unset m
  declare -gA m=()
  local k v
  while IFS='=' read -r k v; do m[$k]=$v; done <"$run/$name.txt"
  say "  measured $name: $(tr '\n' ' ' <"$run/$name.txt")"
}

within() { # <value> <expected> <tolerance>: 0 when |value - expected| <= tolerance
  awk -v v="$1" -v e="$2" -v t="$3" 'BEGIN { d = v - e; if (d < 0) d = -d; exit !(d <= t) }'
}
between() { # <value> <lo> <hi>
  awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'
}

check_lights() { # <label> <x> <y>: positions and size of the lights, no glyph
  local label=$1 x=$2 y=$3 name ex ok details=""
  ok=0
  for name in close minimize zoom; do
    case $name in close) ex=$GF_TB_CLOSE_X ;; minimize) ex=$GF_TB_MIN_X ;; zoom) ex=$GF_TB_ZOOM_X ;; esac
    within "${m[${name}_cx]}" $((x + ex)) 0.75 && within "${m[${name}_cy]}" $((y - GF_TB_MID)) 0.75 && within "${m[${name}_d]}" 14 1 \
      || ok=1
    details+="$name (${m[${name}_cx]},${m[${name}_cy]}) d ${m[${name}_d]}, expected ($((x + ex)),$((y - GF_TB_MID))) d 14; "
  done
  check "$label: lights" "$ok" "$details"
}

check_glyphs() { # <label> <0 = expect glyphs on all three | 1 = expect none>
  local label=$1 want=$2 ok=0 name
  for name in close minimize zoom; do
    if ((want == 0)); then ((${m[${name}_glyph]:-0} >= 6)) || ok=1; else ((${m[${name}_glyph]:-0} <= 1)) || ok=1; fi
  done
  check "$label" "$ok" "dark glyph pixels: close ${m[close_glyph]}, minimize ${m[minimize_glyph]}, zoom ${m[zoom_glyph]}"
}

check_bar() { # <label>
  local ok=0
  ((m[bar_rows] == GF_TB_HEIGHT && m[bar_bottom_gap] == 0 && m[bar_left_gap] == 0)) || ok=1
  check "$1: titlebar" "$ok" "${m[bar_rows]} rows of bar colour (expected $GF_TB_HEIGHT), gaps: bottom row ${m[bar_bottom_gap]} px, left column ${m[bar_left_gap]} px"
}

check_junction() { # <label>: no curve where the content meets the bar (the content's own pixels fill the cut corners)
  local ok=0
  ((${m[junction_left]:--1} == 0 && ${m[junction_right]:--1} == 0)) || ok=1
  check "$1: bar and content join square" "$ok" "pixels of the cut top corners that differ from the content: left ${m[junction_left]:-?}, right ${m[junction_right]:-?} (before the fix: 21 at radius 12, 98 at radius 26)"
}

check_grey() { # <label> <0 = expect grey lights | 1 = expect coloured lights> [core]
  # core (the light appearance): a coloured light is told from a grey one by the grey inside its 5 px core only; over a
  # light bar the anti-aliased ring of the green light passes for the light grey (chrome_measure.py <light>_grey_core).
  local label=$1 want=$2 key=grey ok=0 name details=""
  [[ ${3:-} == core ]] && key=grey_core
  for name in close minimize zoom; do
    if ((want == 0)); then
      ((${m[${name}_grey]:-0} >= 100)) || ok=1 # a 14-px light is about 150 px
    else
      ((${m[${name}_${key}]:-0} <= 4)) && within "${m[${name}_d]:-0}" 14 1.2 || ok=1
    fi
    details+="$name grey ${m[${name}_grey]} px (core ${m[${name}_grey_core]:-?}), diameter ${m[${name}_d]} (${m[${name}_ref]:-colour}); "
  done
  check "$label" "$ok" "$details"
}

check_corner() { # <label> <lo> <hi> <radius>
  if [[ ${m[background_ok]} != 1 ]]; then
    say "  $1: corner SKIP (background next to the corner too close to the bar colour: not measurable)"
    return
  fi
  local ok=0
  between "${m[corner_diag]}" "$2" "$3" && between "${m[corner_diag_right]}" "$2" "$3" || ok=1
  check "$1: corner radius $4" "$ok" "diagonal inset left ${m[corner_diag]} px, right ${m[corner_diag_right]} px (expected $2-$3), radius about ${m[radius_estimate]}"
}

start_foot() { # <title>: pid in $started; the text cursor is hidden (DECTCEM): it sits in the corner the C2 check measures
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name chrome foot --title "$1" -w 700x420 \
    -o colors-dark.background=d8d8d8 -o colors-light.background=d8d8d8 -o colors-dark.alpha=1 -o colors-light.alpha=1 \
    sh -c 'printf "\033[?25l"; exec sleep 600' >/dev/null 2>&1 </dev/null &
  started=$!
  pids+=("$started")
  sleep 1.5
}

say "chrome: output $out ${mon_w}x${mon_h}, plugin $([[ $plugin == 1 ]] && echo loaded || echo 'NOT loaded (C2: titlebar checks skipped)'), geometry: bar $GF_TB_HEIGHT, lights at $GF_TB_CLOSE_X/$GF_TB_MIN_X/$GF_TB_ZOOM_X, middle $GF_TB_MID"
park

# 1 foot A, active
start_foot gf-chrome-a
read -r ax ay aw ah a_addr < <(geom gf-chrome-a)
[[ -n ${aw:-} ]] || { say "chrome: setup error: window A not found"; exit 2; }
say "1 foot A ${aw}x${ah} at ($ax,$ay) (output px), class $(clients | jq -r --arg a "$a_addr" '.[] | select(.address == $a) | .class'), rounding (getprop) $(rounding_of "$a_addr")"
park
capture a-active
crops a-active "$ax" "$ay" "$aw"
measure a-active "$ax" "$ay" "$aw" "$(rounding_of "$a_addr")"
if ((plugin)); then
  check_lights "A active" "$ax" "$ay"
  check_glyphs "A active, pointer away: no glyph" 1
  check_grey "A active: coloured lights" 1
  check_bar "A"
  check_junction "A"
fi
check_corner "A (third-party)" 3 5 12

if ((plugin)); then
  # 2 hover in the gap between A's close and minimize lights (the cursor image covers no light)
  pointer abs $((ax + (GF_TB_CLOSE_X + GF_TB_MIN_X) / 2)) $((ay - GF_TB_MID)) sleep 400
  capture a-hover
  crops a-hover "$ax" "$ay" "$aw"
  measure a-hover "$ax" "$ay" "$aw"
  check_glyphs "A, pointer between its close and minimize lights: glyphs on all three" 0
  park
  capture a-unhover
  measure a-unhover "$ax" "$ay" "$aw"
  check_glyphs "A, pointer away again: no glyph" 1

  # 3 A inactive: foot B opened (centred, on top of A, focused), then moved to the lower right
  start_foot gf-chrome-b
  read -r bx by bw bh b_addr < <(geom gf-chrome-b)
  if [[ -n ${bw:-} ]]; then
    dispatch "hl.dsp.window.move({ x = $((mon_x + mon_w - bw - 60)), y = $((mon_y + mon_h - bh - 160)), window = 'address:$b_addr' })"
    dispatch "hl.dsp.focus({ window = 'address:$b_addr' })"
    sleep 0.6
    active=$(clients | jq -r '.[] | select(.focusHistoryID == 0) | .title')
    say "3 foot B ${bw}x${bh} moved aside; active window: $active"
    pointer abs $((ax + GF_TB_CLOSE_X)) $((ay - GF_TB_MID)) sleep 400
    capture a-inactive-hover
    crops a-inactive-hover "$ax" "$ay" "$aw"
    measure a-inactive-hover "$ax" "$ay" "$aw"
    [[ $active == gf-chrome-b ]]
    check "A inactive" $? "active: $active"
    check_glyphs "A inactive, pointer on its close light: glyphs on all three" 0
    check_grey "A inactive, pointer on its lights: coloured" 1
    park
    capture a-inactive
    crops a-inactive "$ax" "$ay" "$aw"
    measure a-inactive "$ax" "$ay" "$aw"
    check_grey "A inactive, pointer away: grey lights" 0
    check_glyphs "A inactive, pointer away: no glyph" 1
  else
    check "foot B opened" 1 "window B not found"
  fi

  # 3b the light appearance (audit UX-06): the shell pushes it (feature "appearance") and every titlebar follows it
  say "3b light appearance: the titlebars follow it"
  if HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -e '.features | index("appearance")' >/dev/null 2>&1; then
    set_appearance light
    palette_for Light
    park
    capture a-light
    crops a-light "$ax" "$ay" "$aw"
    measure a-light "$ax" "$ay" "$aw"
    check_bar "A (light)"
    check_lights "A (light)" "$ax" "$ay"
    [[ -n ${bw:-} ]] && check_grey "A inactive (light), pointer away: grey lights" 0
    dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
    sleep 0.6
    park
    capture a-light-active
    measure a-light-active "$ax" "$ay" "$aw"
    check_grey "A active (light): coloured lights" 1 core
    set_appearance dark
    palette_for Dark
    park
    capture a-dark-again
    measure a-dark-again "$ax" "$ay" "$aw"
    check_bar "A (dark again)"
  else
    check "3b: the plugin advertises \"appearance\"" 1 "features $(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -c '.features')"
  fi
fi

# 4 Grassfield Settings
settings=$dev/build/grassfield-settings
if [[ -x $settings ]]; then
  bus=""
  [[ -f $dev/bus.address ]] && bus=$(<"$dev/bus.address")
  "$root/scripts/dev/isolated.sh" --name chrome --config-home "$dev/config" --state-home "$dev/state" -- \
    env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 \
    QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" GRASSFIELD_LANG=en \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" "$settings" >>"$log" 2>&1 </dev/null &
  pids+=("$!")
  sx="" sw=""
  for _ in $(seq 1 40); do
    read -r sx sy sw sh s_addr < <(geom_class org.grassfield.Settings)
    [[ -n $sw ]] && break
    sleep 0.25
  done
  if [[ -n $sw ]]; then
    sleep 1.5
    read -r sx sy sw sh s_addr < <(geom_class org.grassfield.Settings)
    say "4 Settings ${sw}x${sh} at ($sx,$sy), rounding (getprop) $(rounding_of "$s_addr")"
    park
    capture settings
    crops settings "$sx" "$sy" "$sw"
    measure settings "$sx" "$sy" "$sw" "$(rounding_of "$s_addr")"
    if ((plugin)); then
      check_lights "Settings" "$sx" "$sy"
      check_grey "Settings (active): coloured lights" 1
      check_bar "Settings"
      check_junction "Settings"
    fi
    check_corner "Settings (org.grassfield.*)" 7 10 26
    if ((plugin)); then
      pointer abs $((sx + (GF_TB_MIN_X + GF_TB_ZOOM_X) / 2)) $((sy - GF_TB_MID)) sleep 400
      capture settings-hover
      crops settings-hover "$sx" "$sy" "$sw"
      measure settings-hover "$sx" "$sy" "$sw"
      check_glyphs "Settings, pointer between its minimize and zoom lights: glyphs on all three" 0
      park
    fi
  else
    check "Settings opened" 1 "no org.grassfield.Settings window (see $log)"
  fi
else
  say "4 Settings: SKIP ($settings not built: apps/settings/build-direct.sh)"
fi

say "captures and crops: $run"
if ((fail)); then say "chrome: FAIL"; exit 1; fi
say "chrome: PASS"
exit 0
