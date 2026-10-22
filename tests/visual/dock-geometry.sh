#!/usr/bin/env bash
# Dock pass 2, geometry (docs/specs/dock.md requirements 22-24), on the nested session with the REAL pointer:
#   size        dock.size 32 / 48 / 96: the exclusive zone (the output's reserved area), the tile pitch and the minimize target follow
#   position    left / right / bottom: the reserved area is on that edge only, the tiles are a column (x constant, y rising, Trash last),
#               the minimize target is on that edge, autohide reveals from that edge
#   one Dock    the Dock is on one output; the pointer resting on the bottom (or side) edge of the other output brings it there,
#               the zone moves with it
#   resize      dragging the separator changes the size live (persisted on release); the resize cursor is captured
# Captures (cropped; dark and light; small and large; left and right with a tooltip and a menu; the second output) go to
# .dev/visual/dock-geometry/ to be looked at. Exit status 1 when an assertion fails.
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-geometry.sh [size|position|onedock|resize]     (default: all four parts)
source "$(dirname "$0")/lib.sh"
set +e
out=$VS_STATE/dock-geometry
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${ptr_pid:-} ]] && kill "$ptr_pid" 2>/dev/null
  vs_nested_running && vs_kill_clients
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*
part=${1:-all}
want() { [[ $part == all || $part == "$1" ]]; }
fails=0
check() { if [[ $2 == ok ]]; then echo "PASS $1"; else echo "FAIL $1 ($2)"; fails=$((fails + 1)); fi; }
eq() { [[ $2 == "$3" ]] && check "$1" ok || check "$1" "got '$2', want '$3'"; }

# reserved area of an output: "left top right bottom" (Hyprland's order)
reserved() { "$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$1" '.[] | select(.name == $n) | .reserved | map(tostring) | join(" ")'; }
res_of() { local r; read -ra r <<<"$(reserved "$1")"; case $2 in left) echo "${r[0]}" ;; top) echo "${r[1]}" ;; right) echo "${r[2]}" ;; bottom) echo "${r[3]}" ;; esac; }
mon() { "$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$1" --arg k "$2" '.[] | select(.name == $n) | .[$k]'; }
tiles() { vs_ipc dock tiles; }
index_of() { tiles | jq -r --arg k "$1" 'index($k)'; }
centre() { vs_ipc dock centre "$1" "${2:-$VS_OUTPUT}"; }
# zone of a Dock whose tiles are $1 px: shelf (tile + 2 x padding 10 + dot 4 + gap 4) + margin 6
zone() { echo $(($1 + 20 + 8 + 6)); }
grab() { # name x y w h [output]: a crop of the output
  "$VS_ROOT/scripts/dev/shot.sh" "dgeo-$1" "${6:-$VS_OUTPUT}" >/dev/null
  magick "$VS_DEV/shots/dgeo-$1.png" -crop "${4}x${5}+${2}+${3}" +repage "$out/$1.png"
  echo "shot $1 (${4}x${5}+${2}+${3} of $(magick identify -format '%wx%h' "$VS_DEV/shots/dgeo-$1.png"))"
}
settle() { vs_sleep "${1:-1.2}"; }
mouse() { "$VS_ROOT/scripts/dev/pointer.sh" output "${OUT:-$VS_OUTPUT}" "$@" >/dev/null; }

vs_session en
vs_reset dark 0.25
vs_foot dgeo-one 70x16 >/dev/null
vs_wait_clients 1 >/dev/null
vs_sleep 1
vs_ipc dock magnify 1.6 false >/dev/null
vs_ipc dock autohide false >/dev/null
vs_ipc dock position bottom >/dev/null
vs_ipc dock size 48 >/dev/null
settle
W=$(mon "$VS_OUTPUT" width)
H=$(mon "$VS_OUTPUT" height)
echo "output $VS_OUTPUT ${W}x${H}, Dock on $(vs_ipc dock screen), tiles $(tiles), reserved $(reserved "$VS_OUTPUT")"
eq "the Dock starts on the primary output" "$(vs_ipc dock screen)" "$VS_OUTPUT"

if want size; then
# ---- size -------------------------------------------------------------------------------------------------------------------------
for size in 32 48 96; do
  vs_ipc dock size "$size" >/dev/null
  settle
  eq "size $size: the zone at the bottom is $(zone "$size")" "$(res_of "$VS_OUTPUT" bottom)" "$(zone "$size")"
  p0=$(centre 0)
  p1=$(centre 1)
  pitch=$(( $(cut -d' ' -f1 <<<"$p1") - $(cut -d' ' -f1 <<<"$p0") ))
  eq "size $size: the tile pitch is $((size + 4))" "$pitch" "$((size + 4))"
  r=$(vs_ipc dock targetrect "$VS_OUTPUT")
  eq "size $size: the minimize target is $size px square" "$(jq -r '[.w, .h] | join("x")' <<<"$r")" "${size}x${size}"
  eq "size $size: the minimize target sits on the shelf (bottom edge at $((H - 6 - 10 - 8)))" "$(jq -r '.y + .h' <<<"$r")" "$((H - 6 - 10 - 8))"
done
for size in 32 96; do
  vs_ipc dock size "$size" >/dev/null
  settle
  grab "bottom-$size-dark" 360 $((H - 300)) 1200 300
done
vs_ipc dock size 48 >/dev/null
fi

if want position; then
# ---- position ---------------------------------------------------------------------------------------------------------------------
foot=$(index_of foot)
for edge in left right; do
  vs_ipc dock position "$edge" >/dev/null
  settle
  other=$([[ $edge == left ]] && echo right || echo left)
  eq "$edge: the zone is on the $edge edge ($(zone 48))" "$(res_of "$VS_OUTPUT" "$edge")" "$(zone 48)"
  eq "$edge: nothing is reserved at the bottom or the $other" "$(res_of "$VS_OUTPUT" bottom) $(res_of "$VS_OUTPUT" "$other")" "0 0"
  n=$(tiles | jq 'length')
  xs=""
  ys=""
  for i in $(seq 0 $((n - 1))); do
    c=$(centre "$i")
    xs+="$(cut -d' ' -f1 <<<"$c") "
    ys+="$(cut -d' ' -f2 <<<"$c") "
  done
  eq "$edge: every tile has the same x" "$(tr ' ' '\n' <<<"$xs" | sed '/^$/d' | sort -u | wc -l)" 1
  sorted=$(tr ' ' '\n' <<<"$ys" | sed '/^$/d' | sort -n | tr '\n' ' ')
  eq "$edge: the tiles go top to bottom in order" "$ys" "$sorted"
  eq "$edge: the Trash is the last tile" "$(tiles | jq -r 'last')" "trash"
  want=$([[ $edge == left ]] && echo 48 || echo $((W - 48)))
  eq "$edge: the icon centre is $want px across ($(zone 48) zone: 6 + 10 + 8 + 24)" "$(cut -d' ' -f1 <<<"$(centre 0)")" "$want"
  r=$(vs_ipc dock targetrect "$VS_OUTPUT")
  monx=$(mon "$VS_OUTPUT" x)
  wantx=$([[ $edge == left ]] && echo $((monx + 24)) || echo $((monx + W - 48 - 24)))
  eq "$edge: the minimize target is on that edge (x $wantx)" "$(jq -r '.x' <<<"$r")" "$wantx"
done

# captures: left and right, small and large, dark and light, with a tooltip and with a menu
for appearance in dark light; do
  vs_ipc controlcenter appearance "$appearance" >/dev/null
  for edge in left right; do
    vs_ipc dock position "$edge" >/dev/null
    for size in 32 96; do
      vs_ipc dock size "$size" >/dev/null
      settle
      c=$(centre "$foot")
      cx=$(cut -d' ' -f1 <<<"$c")
      cy=$(cut -d' ' -f2 <<<"$c")
      mouse abs "$cx" "$cy"
      vs_sleep 1.2
      if [[ $edge == left ]]; then region="0 $((cy - 380)) 520 760"; else region="$((W - 520)) $((cy - 380)) 520 760"; fi
      # shellcheck disable=SC2086
      grab "$edge-$size-$appearance-tooltip" $region
      mouse abs "$VS_PARK_X" "$VS_PARK_Y"
      vs_sleep 0.4
      vs_ipc dock menu "$foot" "$VS_OUTPUT" >/dev/null
      vs_sleep 1
      # shellcheck disable=SC2086
      grab "$edge-$size-$appearance-menu" $region
      vs_ipc menubar close >/dev/null
      vs_sleep 0.4
    done
  done
done
vs_ipc controlcenter appearance dark >/dev/null
vs_ipc dock size 48 >/dev/null

# autohide reveals from the side edge, sideways
vs_ipc dock position left >/dev/null
vs_ipc dock autohide true >/dev/null
mouse abs 600 540
settle 2.8
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
[[ $s == hidden* ]] && check "left: auto-hide hides sideways" ok || check "left: auto-hide hides sideways" "$s"
eq "left: no zone while auto-hidden" "$(res_of "$VS_OUTPUT" left)" 0
grab left-hidden 0 $((H / 2 - 380)) 520 760
mouse abs 0 540
vs_sleep 1
s=$(vs_ipc dock hidestate "$VS_OUTPUT")
[[ $s == shown* ]] && check "left: the pointer on the left edge reveals the Dock" ok || check "left: the pointer on the left edge reveals the Dock" "$s"
grab left-revealed 0 $((H / 2 - 380)) 520 760
mouse abs 600 540
vs_ipc dock autohide false >/dev/null
vs_ipc dock position bottom >/dev/null
settle
fi

if want onedock; then
# ---- one Dock across displays -----------------------------------------------------------------------------------------------------
second=$("$VS_ROOT/scripts/dev/pointer.sh" outputs | awk '{print $1}' | grep -v "^$VS_OUTPUT$" | head -1)
echo "second output: '${second:-none}'"
if [[ -n $second ]]; then
  W2=$(mon "$second" width)
  H2=$(mon "$second" height)
  eq "$second has no Dock before the pointer reaches its edge" "$(res_of "$second" bottom)" 0
  OUT=$second mouse abs $((W2 / 2)) $((H2 / 2))
  vs_sleep 0.5
  OUT=$second mouse abs $((W2 / 2)) $((H2 - 1))
  vs_sleep 1.2
  eq "the pointer resting on the bottom edge of $second brings the Dock there" "$(vs_ipc dock screen)" "$second"
  eq "the zone moved with it" "$(res_of "$second" bottom) $(res_of "$VS_OUTPUT" bottom)" "$(zone 48) 0"
  OUT=$second mouse abs $((W2 / 2)) $((H2 / 2))
  vs_sleep 1
  grab second-bottom 0 $((H2 - 260)) "$W2" 260 "$second"
  vs_ipc controlcenter appearance light >/dev/null
  vs_sleep 0.6
  grab second-bottom-light 0 $((H2 - 260)) "$W2" 260 "$second"
  vs_ipc controlcenter appearance dark >/dev/null
  tr=$(vs_ipc dock targetrect "$second")
  mx=$(mon "$second" x)
  my=$(mon "$second" y)
  ok=$(jq -r --argjson mx "$mx" --argjson my "$my" --argjson w "$W2" --argjson h "$H2" '(.x >= $mx and .x < $mx + $w and .y >= $my and .y < $my + $h) | tostring' <<<"$tr")
  eq "the minimize target is on $second (layout x $mx..$((mx + W2)), y $my..$((my + H2)); got $tr)" "$ok" true
  # back to the primary output
  mouse abs $((W / 2)) $((H / 2))
  vs_sleep 0.5
  mouse abs $((W / 2)) $((H - 1))
  vs_sleep 1.2
  eq "the pointer on the bottom edge of $VS_OUTPUT takes it back" "$(vs_ipc dock screen)" "$VS_OUTPUT"
  eq "and the zone with it" "$(res_of "$VS_OUTPUT" bottom) $(res_of "$second" bottom)" "$(zone 48) 0"
  # a side Dock: the left edge of the second output
  vs_ipc dock position left >/dev/null
  settle
  OUT=$second mouse abs $((W2 / 2)) $((H2 / 2))
  vs_sleep 0.5
  OUT=$second mouse abs 0 $((H2 / 2))
  vs_sleep 1.2
  eq "left: the pointer resting on the left edge of $second brings the Dock there" "$(vs_ipc dock screen)" "$second"
  eq "left: the zone is on its left edge" "$(res_of "$second" left) $(res_of "$VS_OUTPUT" left)" "$(zone 48) 0"
  OUT=$second mouse abs $((W2 / 2)) $((H2 / 2))
  vs_sleep 1
  grab second-left 0 $((H2 / 2 - 380)) 520 760 "$second"
  mouse abs $((W / 2)) $((H / 2))
  vs_sleep 0.4
  # back on the primary output (the left edge of GF-REF, the Dock still on the left)
  mouse abs 0 $((H / 2))
  vs_sleep 1.2
  eq "left: the pointer on the left edge of $VS_OUTPUT takes it back" "$(vs_ipc dock screen)" "$VS_OUTPUT"
fi

fi

if want resize; then
# ---- resize by dragging the separator ------------------------------------------------------------------------------------------------
vs_ipc dock position bottom >/dev/null
vs_ipc dock size 48 >/dev/null
settle
mouse abs $((W / 2)) $((H / 2))
vs_sleep 0.4
mouse abs $((W / 2)) $((H - 1))
vs_sleep 1.2
eq "the Dock is on $VS_OUTPUT for the resize" "$(vs_ipc dock screen)" "$VS_OUTPUT"
mouse abs "$VS_PARK_X" "$VS_PARK_Y"
vs_sleep 0.6
sep=$(tiles | jq -r 'map(. == "separator") | index(true)')
echo "separator index: $sep (tiles $(tiles))"
if [[ $sep != null && -n $sep ]]; then
  c=$(centre "$sep")
  sx=$(cut -d' ' -f1 <<<"$c")
  sy=$(cut -d' ' -f2 <<<"$c")
  mouse abs "$sx" "$sy"
  vs_sleep 0.6
  "$VS_ROOT/scripts/dev/shot.sh" --cursor dgeo-cursor "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/dgeo-cursor.png" -crop 400x160+$((sx - 200))+$((H - 160)) +repage "$out/separator-cursor.png"
  echo "shot separator-cursor"
  # press, drag 20 px up (the size grows by 40), hold, release, all in one pointer invocation
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs "$sx" "$sy" sleep 200 down sleep 200 drag "$sx" $((sy - 20)) sleep 2500 up sleep 200 >/dev/null &
  ptr_pid=$!
  vs_sleep 1.8
  live=$(vs_ipc dock sizenow)
  echo "size while held: $live"
  eq "dragging the separator up changes the size live (20 px up: 48 -> 88)" "$live" 88
  eq "and the zone follows live" "$(res_of "$VS_OUTPUT" bottom)" "$(zone 88)"
  grab resize-held 360 $((H - 300)) 1200 300
  wait "$ptr_pid"
  ptr_pid=""
  vs_sleep 1
  eq "after the release the size is kept (88)" "$(vs_ipc dock sizenow)" 88
  cfg=$(find "$VS_DEV" -name grassfield.json -path '*config*' 2>/dev/null | head -1)
  eq "and persisted in grassfield.json ($cfg)" "$(jq -r '.dock.size' "$cfg" 2>/dev/null)" 88
  # drag down far: clamped at the smallest size
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs "$sx" $((H - 60)) sleep 100 >/dev/null
  c=$(centre "$sep")
  sx=$(cut -d' ' -f1 <<<"$c")
  sy=$(cut -d' ' -f2 <<<"$c")
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs "$sx" "$sy" sleep 200 down sleep 200 drag "$sx" $((H - 1)) sleep 400 up sleep 200 >/dev/null
  vs_sleep 1
  eq "dragging far down stops at the smallest size (32)" "$(vs_ipc dock sizenow)" 32
fi

fi

eq "no QML error in the shell log" "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" 0
echo "captures in $out"
exit $((fails > 0))
