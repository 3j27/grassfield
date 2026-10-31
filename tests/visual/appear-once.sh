#!/usr/bin/env bash
# "Everything appears once" (ADR-0040 section 7, ID-16; steps 3 and 6): nested, light appearance, a picture wallpaper and a
# non-default accent. At a shell start and at a restart (the second start finds the picture's still in wallpaper.json):
#   - the first wallpaper kind logged ("grassfield-shell: wallpaper first <kind>") is the final one (wallpaper.json `shown`);
#   - no surface is shown twice on an output without being hidden in between ("grassfield-shell: shown|hidden <surface>
#     <output> <ms>", shell/services/Journal.qml);
#   - the menu bar, the Dock and the desktop icons come after the wallpaper, and the entrance ended because everything was
#     ready, not on its timeout ("grassfield-shell: entrance (ready"; a timeout is reported, not failed: a slow machine);
#   - the menu bar's tone does not change in the first 3 s (`bartone status` sampled every 100 ms from the start).
# The lock and unlock part of section 7 comes with step 4b. Pictures are generated under .dev, never committed.
# Usage (bare command): tests/visual/appear-once.sh
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-once
mkdir -p "$pics"
# A picture whose top strip is light (a dark bar tone) and whose mean is far from the default artwork's ground.
magick -size 1920x1080 gradient:'#f2efe6'-'#5a7a8c' "$pics/once.png"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

log=$VS_DEV/shell.log
out=$VS_OUTPUT

# The journal checks of one start (the shell log of that start).
journal_checks() {
  local label=$1 first final order
  first=$(grep -m1 -o "grassfield-shell: wallpaper first [a-z]* .*output=$out" "$log" | awk '{print $4}')
  local state
  state=$(find "$VS_DEV/state" -name wallpaper.json 2>/dev/null | head -1)
  final=$([[ -n $state ]] && jq -r --arg o "$out" '.shown[$o].kind // ""' "$state" 2>/dev/null)
  check "$label: the first wallpaper is the final one (first $first, final $final)" test -n "$first" -a "$first" = "$final"
  # shown/hidden pairs per surface and output: a second `shown` needs a `hidden` before it.
  local twice
  twice=$(grep -o "grassfield-shell: \(shown\|hidden\) [a-z]* [^ ]* [0-9]*" "$log" | awk '
    { key = $3 " " $4; if ($2 == "shown") { if (up[key]) print key; up[key] = 1 } else up[key] = 0 }')
  check "$label: no surface shown twice without being hidden (${twice:-none})" test -z "$twice"
  # The bars after the wallpaper.
  local wp bar
  wp=$(grep -m1 -o "grassfield-shell: shown wallpaper $out [0-9]*" "$log" | awk '{print $5}')
  for s in menubar dock; do
    # The Dock is on one output (the focused one at the start), not necessarily this one.
    if [[ $s == dock ]]; then
      bar=$(grep -m1 -o "grassfield-shell: shown dock [^ ]* [0-9]*" "$log" | awk '{print $5}')
    else
      bar=$(grep -m1 -o "grassfield-shell: shown $s $out [0-9]*" "$log" | awk '{print $5}')
    fi
    check "$label: $s after the wallpaper (wallpaper ${wp:-?} ms, $s ${bar:-?} ms)" test -n "$wp" -a -n "$bar" -a "${bar:-0}" -ge "${wp:-1}"
  done
  order=$(grep -m1 -o "grassfield-shell: entrance ([a-z]*" "$log" | awk '{print $3}')
  check "$label: the entrance happened (${order#(})" test -n "$order"
  [[ $order == "(ready" ]] || echo "info: $label: the entrance ended on its timeout ($(grep -m1 "grassfield-shell: entrance" "$log"))"
}

# Tones of the output sampled every 100 ms for 3 s from now; prints the distinct ones.
sample_tones() {
  local i t seen=""
  for i in $(seq 1 30); do
    t=$(vs_ipc bartone status 2>/dev/null | jq -r --arg o "$out" '.[$o].tone // empty' 2>/dev/null)
    [[ -n $t && " $seen " != *" $t "* ]] && seen="$seen $t"
    sleep 0.1
  done
  echo "$seen"
}

vs_session
vs_reset
cfg=$VS_DEV/config/grassfield.json
printf '{"version":1,"appearance":"light","accent":{"color":"pink"},"wallpaper":{"source":"file","path":"%s","fit":"fill"}}\n' "$pics/once.png" > "$cfg"

# First start with this configuration (no still yet: the picture is prepared; the window maps with it or after the bound).
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop"
tones=$(sample_tones)
vs_sleep 2
journal_checks "first start"
check "first start: one bar tone in the first 3 s (${tones# })" test "$(wc -w <<<"$tones")" -le 1

# Restart: the still recorded by the first start is the first frame, with its stored tone.
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop"
tones=$(sample_tones)
vs_sleep 2
journal_checks "restart"
check "restart: one bar tone in the first 3 s (${tones# })" test "$(wc -w <<<"$tones")" -le 1
vs_capture "appear-once-restart" >/dev/null || fail=1

exit $fail
