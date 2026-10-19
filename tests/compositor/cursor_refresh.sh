#!/usr/bin/env bash
# Scenario (FR39-FR40; Settings > Accessibility > Pointer, ADR-0014): with the plugin feature "cursor-refresh", a pointer
# that does not move is drawn at the new size as soon as the shell applies it (macOS: the pointer grows while the slider
# moves), keeps its shape and does not move. Without the feature the shell still applies the size and sends no refresh.
#
# Usage: tests/compositor/cursor_refresh.sh [check | baseline | stress [seconds]]
#   check     plugin loaded with cursor-refresh: the arrow over the desktop and the I-beam over foot, each 24 -> 48 -> 96
#             -> 24 with the pointer still; a pointer foot hides while typing stays hidden; 10 refreshes/s for 3 s and a
#             1000-call flood; plugin unload (no refresh: the new size waits for a shape change) and load again.
#   baseline  no cursor-refresh (scripts/dev/nested-up.sh --no-plugin): the shell applies the size (its setcursor lines,
#             capabilities "ready degraded"), the still pointer keeps its old size, a shape change draws the new one.
#   stress    (default 600 s) the verb 10 times per second and a new pointer.size every 3 s, nothing else; meant to run
#             next to tests/compositor/soak.sh (C1). PASS when Hyprland is alive and at most 1 % of the calls failed.
# NESTED only: needs scripts/dev/nested-up.sh, grassfield-shell and the dev cursor theme (`just cursors`). The size is set
# as Settings sets it: pointer.size in the dev settings file (.dev/config/grassfield.json, restored at exit). Pointer
# input through scripts/dev/pointer.sh, captures through scripts/dev/shot.sh, hyprctl through scripts/nestctl (read-only
# queries, the verb, plugin unload/load). The size drawn = bounding box of (capture with the pointer) - (reference capture
# with the pointer away), in a 240 px square centred on the pointer.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log and crops: .dev/cursor-refresh/run-<timestamp>/.
set -uo pipefail

mode=${1:-check}
stress_secs=${2:-600}
case $mode in
  check | baseline) ;;
  stress) [[ $stress_secs =~ ^[1-9][0-9]*$ ]] || { echo "usage: cursor_refresh.sh [check | baseline | stress [seconds]]" >&2; exit 2; } ;;
  *) echo "usage: cursor_refresh.sh [check | baseline | stress [seconds]]" >&2; exit 2 ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${CR_OUTPUT:-GF-REF}
plugin=$root/compositor/build/grassfield-compositor.so
main=$(cat "$dev/main.instance" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh).
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "cursor_refresh: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "cursor_refresh: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in jq grim magick foot; do
  command -v "$tool" >/dev/null || { echo "cursor_refresh: $tool is needed" >&2; exit 2; }
done
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] || { echo "cursor_refresh: grassfield-shell is not running" >&2; exit 2; }
theme=$(tr '\0' '\n' <"/proc/$shell_pid/environ" 2>/dev/null | sed -n 's/^HYPRCURSOR_THEME=//p')
[[ $theme == grassfield-cursors ]] \
  || { echo "cursor_refresh: the nested shell has cursor theme '${theme:-none}', not grassfield-cursors (run: just cursors, then restart the nested session)" >&2; exit 2; }

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
features() {
  local reply
  reply=$(nestctl -j grassfield 2>/dev/null) || true
  jq -c '.features // []' <<<"$reply" 2>/dev/null || echo '[]'
}
has_refresh() { features | jq -e 'index("cursor-refresh")' >/dev/null; }
if [[ $mode != baseline ]] && ! has_refresh; then
  echo "cursor_refresh: the nested plugin does not advertise cursor-refresh (features $(features))" >&2
  exit 2
fi
if [[ $mode == baseline ]] && has_refresh; then
  echo "cursor_refresh: baseline needs a session without cursor-refresh (scripts/dev/nested-up.sh --no-plugin)" >&2
  exit 2
fi

stamp=$(date +%Y%m%d-%H%M%S)
work=$dev/cursor-refresh/run-$stamp-$mode
mkdir -p "$work" "$dev/shots/cursor-refresh-$stamp"
log=$work/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

settings=$dev/config/grassfield.json
backup=$work/settings.backup
had_settings=0
[[ -f $settings ]] && { cp "$settings" "$backup"; had_settings=1; }
# Never the defaults file as a base: its Dock pins a browser and a file manager (scripts/dev/shell-run.sh writes the dev
# file with the foot-only Dock and no idle lock; the same minimal content when it is missing).
base=$backup
((had_settings)) || printf '{"version":1,"lock":{"idleMinutes":0},"dock":{"pinned":["foot"]}}\n' >"$base"
foot_pid=""
cleanup() {
  [[ -n $foot_pid ]] && kill "$foot_pid" 2>/dev/null
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
}
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

read -r mon_x mon_y mon_w mon_h < <(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_x:-} ]] || { echo "cursor_refresh: output $out not found" >&2; exit 2; }
C=240 # crop side; the pointer is at (C/2, C/2) in every crop

cursorpos() { nestctl -j cursorpos | jq -r '"\(.x) \(.y)"'; }

# pointer.size as Settings writes it; waits for the shell's `setcursor` line for that size, then for the answer and the
# refresh (the shell sends the refresh only after Hyprland answered "ok").
set_size() { # <px>
  local before n=0
  before=$(grep -cE "pointer /setcursor [A-Za-z0-9_-]+ $1( |\$)" "$dev/shell.log" 2>/dev/null)
  mkdir -p "$dev/config"
  jq --argjson v "$1" '.pointer.size = $v' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  for _ in $(seq 1 50); do
    n=$(grep -cE "pointer /setcursor [A-Za-z0-9_-]+ $1( |\$)" "$dev/shell.log" 2>/dev/null)
    ((n > before)) && break
    sleep 0.1
  done
  ((n > before)) || { say "  (no setcursor $1 line in the shell log)"; return 1; }
  sleep 0.8
}

# The headless output has no hardware cursor plane: every capture shows the pointer (with or without grim -c). So the
# reference is the same crop captured while the pointer is far away (half the output to the side, never a corner),
# taken before the pointer comes to (px, py) and stays there.
cur_ref=""
reference() { # <label> <px> <py>
  local a fx=$(($2 >= mon_w / 2 ? $2 - mon_w / 2 + 40 : $2 + mon_w / 2 - 40))
  pointer abs "$fx" "$3" sleep 50
  sleep 0.4
  a=$("$root/scripts/dev/shot.sh" "cursor-refresh-$stamp/$1-ref" "$out" 2>>"$log") || return 1
  magick "$a" -crop "${C}x${C}+$(($2 - C / 2))+$(($3 - C / 2))" +repage "$work/$1-ref.png" 2>>"$log" || return 1
  cur_ref=$work/$1-ref.png
}

# "w h x y mean" of the drawn pointer in the crop around (px, py) (output coordinates) against the current reference;
# "0 0 0 0 0" when nothing differs.
measure() { # <label> <px> <py>
  local a r
  a=$("$root/scripts/dev/shot.sh" --cursor "cursor-refresh-$stamp/$1" "$out" 2>>"$log") || { echo "0 0 0 0 0"; return; }
  local geo="${C}x${C}+$(($2 - C / 2))+$(($3 - C / 2))"
  magick "$a" -crop "$geo" +repage "$work/$1.png" 2>>"$log"
  [[ -n $cur_ref ]] || { echo "0 0 0 0 0"; return; }
  r=$(magick "$work/$1.png" "$cur_ref" -compose difference -composite -colorspace gray -threshold 4% \
    -format '%[fx:mean] %@' info: 2>>"$log")
  if [[ $r =~ ^([0-9.e+-]+)\ ([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] && [[ ${BASH_REMATCH[1]} != 0 ]]; then
    echo "${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[5]} ${BASH_REMATCH[1]}"
  else
    echo "0 0 0 0 0"
  fi
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print 0; else printf "%.3f", a / b }'; }
within() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }
same_crop() { # <label a> <label b>: number of differing pixels between two saved crops
  magick compare -metric AE "$work/$1.png" "$work/$2.png" null: 2>&1 | awk '{ print int($1) }'
}

# Starts from 24 px: the shell sends nothing when 24 already is its size, so no line is required here.
start_at_24() {
  mkdir -p "$dev/config"
  jq '.pointer.size = 24' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  sleep 1.5
}

declare -A seq_ratio=() seq_h24=()
# One still-pointer sequence 24 -> 48 -> 96 -> 24 at (px, py). Expect: "grow" (cursor-refresh) or "stay" (no refresh).
sequence() { # <name> <px> <py> <grow|stay>
  local name=$1 px=$2 py=$3 expect=$4 s w h x y m pos pos0 r0="" h24=0 w24=0
  start_at_24
  reference "$name" "$px" "$py" || { check "$name: reference capture" 1 "shot failed"; return; }
  pointer abs "$px" "$py" sleep 50
  sleep 0.6
  pos0=$(cursorpos)
  for s in 24 48 96 24; do
    local label="$name-$s"
    [[ $s == 24 && -n $r0 ]] && label="$name-24-again"
    if [[ -n $r0 ]]; then
      set_size "$s" || { check "$name: size $s applied by the shell" 1 "no setcursor line"; continue; }
    fi
    read -r w h x y m < <(measure "$label" "$px" "$py")
    pos=$(cursorpos)
    say "  $label: drawn ${w}x${h} at (+$x,+$y) in the crop, cursorpos $pos"
    check "$name $s: pointer not moved" "$([[ $pos == "$pos0" ]]; echo $?)" "cursorpos $pos (was $pos0)"
    check "$name $s: pointer drawn at the hotspot" "$( ((w > 0 && x <= C / 2 + 2 && y <= C / 2 + 2 && x + w >= C / 2 - 2 && y + h >= C / 2 - 2)); echo $?)" \
      "box ${w}x${h}+$x+$y around ($((C / 2)),$((C / 2)))"
    if [[ -z $r0 ]]; then
      r0=$(ratio "$w" "$h") h24=$h w24=$w
      seq_ratio[$name]=$r0 seq_h24[$name]=$h
      continue
    fi
    local r q
    r=$(ratio "$w" "$h")
    q=$(ratio "$h" "$h24")
    if [[ $label == "$name-24-again" ]]; then
      local d
      d=$(same_crop "$name-24" "$name-24-again")
      check "$name back to 24: same image as the first 24" "$( ((d <= 20)); echo $?)" "$d px differ, ${w}x${h} vs ${w24}x${h24}"
      continue
    fi
    check "$name $s: same shape" "$(within "$r" "$(awk -v r="$r0" 'BEGIN { print r - 0.12 }')" "$(awk -v r="$r0" 'BEGIN { print r + 0.12 }')"; echo $?)" \
      "w/h $r vs $r0 at 24"
    if [[ $expect == grow ]]; then
      local lo hi
      lo=$(awk -v s="$s" 'BEGIN { print s / 24 * 0.8 }') hi=$(awk -v s="$s" 'BEGIN { print s / 24 * 1.2 }')
      check "$name $s: drawn at the new size without moving" "$(within "$q" "$lo" "$hi"; echo $?)" "height ${h} = ${q} x the 24 px height (want ${lo}-${hi})"
    else
      check "$name $s: still pointer keeps the old size (no refresh)" "$(within "$q" 0.9 1.1; echo $?)" "height ${h} = ${q} x the 24 px height"
    fi
  done
}

say "cursor_refresh $mode: run $work, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), output $out ${mon_w}x${mon_h}"
say "plugin features: $(features); shell capabilities: $("$root/tests/visual/ipc.sh" capabilities status 2>>"$log")"

if [[ $mode == stress ]]; then
  # The verb at 10/s and a new size every 3 s (the shell then sends its own setcursor + refresh) for stress_secs.
  sizes=(24 48 96 64 32)
  calls=0 failed=0 changes=0
  end=$((SECONDS + stress_secs))
  while ((SECONDS < end)); do
    if ((calls % 30 == 0)); then
      jq --argjson v "${sizes[changes % ${#sizes[@]}]}" '.pointer.size = $v' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
      changes=$((changes + 1))
    fi
    nestctl dispatch 'hl.plugin.grassfield.cursor_refresh()' >/dev/null 2>>"$log" || failed=$((failed + 1))
    calls=$((calls + 1))
    ((calls % 1000 == 0)) && say "  $calls calls, $failed failed, $changes sizes"
    kill -0 "$hypr_pid" 2>/dev/null || break
    sleep 0.1
  done
  say "stress: $calls calls in ${stress_secs} s, $failed failed, $changes size changes"
  kill -0 "$hypr_pid" 2>/dev/null
  check "nested Hyprland alive" $? "pid $hypr_pid"
  check "calls answered" "$( ((failed * 100 <= calls)); echo $?)" "$failed of $calls failed"
  check "plugin still advertises cursor-refresh" "$(has_refresh; echo $?)" "$(features)"
  grep -a '\[grassfield\] cursor_refresh' "$dev/hyprland.log" 2>/dev/null | tail -n 5 >>"$log"
  if ((fail == 0)); then say "cursor_refresh stress: PASS"; else say "cursor_refresh stress: FAIL"; fi
  say "cursor_refresh stress: log $log"
  exit "$fail"
fi

# 1. The arrow over the desktop (no window there): the shell's desktop surface sets the default shape.
ax=$((mon_w / 2 - 300)) ay=$((mon_h / 2))
if [[ $mode == check ]]; then
  say "arrow over the desktop, pointer still at ($ax,$ay)"
  sequence arrow "$ax" "$ay" grow
else
  say "arrow over the desktop without cursor-refresh, pointer still at ($ax,$ay)"
  sequence arrow "$ax" "$ay" stay
  # The size was applied (the shell works): a shape change draws it. Entering another surface is not enough: Hyprland
  # 0.56.2 ignores a shape name set again (setCursorFromName returns when the name is unchanged and not forced), and the
  # desktop and the Dock both set "default". So a foot opens under the pointer (I-beam) and closes again (arrow).
  set_size 96 || true
  read -r w h x y m < <(measure "arrow-96-still" "$ax" "$ay")
  say "  96 applied, pointer still: drawn ${w}x${h}"
  pointer abs "$ax" $((mon_h - 20)) sleep 300 abs "$ax" "$ay" sleep 50
  sleep 0.6
  read -r w h x y m < <(measure "arrow-96-after-the-dock" "$ax" "$ay")
  say "  96 applied, pointer over the Dock and back (same shape name): drawn ${w}x${h}"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
  foot_pid=$!
  for _ in $(seq 1 30); do
    nestctl -j clients | jq -e --argjson p "$foot_pid" 'any(.[]; .pid == $p and .mapped)' >/dev/null && break
    sleep 0.2
  done
  pointer abs $((ax + 1)) "$ay" sleep 300 abs "$ax" "$ay" sleep 50 # over foot: the I-beam
  kill "$foot_pid" 2>/dev/null
  foot_pid=""
  sleep 0.8 # foot gone: the desktop under the pointer sets the arrow again
  pointer abs "$ax" "$ay" sleep 50
  read -r w h x y m < <(measure "arrow-96-after-shape-change" "$ax" "$ay")
  q=$(ratio "$h" "${seq_h24[arrow]:-0}")
  say "  after a shape change: drawn ${w}x${h} (${q} x the 24 px height)"
  check "a shape change draws the applied size (96)" "$(within "$q" 3.2 4.8; echo $?)" "height $h = $q x"
  status=$("$root/tests/visual/ipc.sh" capabilities status 2>>"$log")
  check "shell without the plugin: degraded mode" "$([[ $status == "ready degraded" ]]; echo $?)" "$status"
  sent=$(grep -cE "pointer /setcursor" "$dev/shell.log")
  check "the shell applied every size" "$( ((sent >= 3)); echo $?)" "$sent setcursor line(s) in the shell log"
  errors=$(grep -cE "TypeError|ReferenceError|is not a function|is not defined" "$dev/shell.log")
  check "shell log has no script error" "$( ((errors == 0)); echo $?)" "$errors line(s)"
  start_at_24
fi

if [[ $mode == check ]]; then
  # 2. The I-beam over foot (compositor-drawn shape "text"): stays an I-beam at every size. foot hides the pointer while
  #    typing (a null cursor surface), which section 2b uses.
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot -o mouse.hide-when-typing=yes >/dev/null 2>&1 </dev/null &
  foot_pid=$!
  geom=""
  for _ in $(seq 1 30); do
    geom=$(nestctl -j clients | jq -r --argjson p "$foot_pid" --argjson mx "$mon_x" --argjson my "$mon_y" \
      '[.[] | select(.pid == $p and .mapped)][0] | select(. != null) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"')
    [[ -n $geom ]] && break
    sleep 0.2
  done
  read -r fx fy fw fh <<<"${geom:-x x x x}"
  if [[ -z $geom ]] || ((fx < 0 || fy < 0 || fx + fw > mon_w || fy + fh > mon_h)); then
    check "foot window on $out for the I-beam" 1 "geometry '${geom}'"
  else
    bx=$((fx + fw / 2)) by=$((fy + fh * 2 / 3))
    say "I-beam over foot ${fw}x${fh} at ($fx,$fy), pointer still at ($bx,$by)"
    sequence ibeam "$bx" "$by" grow
    check "the I-beam is not the arrow" "$(awk -v a="${seq_ratio[arrow]:-0}" -v i="${seq_ratio[ibeam]:-9}" 'BEGIN { exit !(i < a - 0.15) }'; echo $?)" \
      "w/h at 24 px: I-beam ${seq_ratio[ibeam]:-?} vs arrow ${seq_ratio[arrow]:-?}"

    # 2b. A hidden pointer stays hidden: the forced redraw would show it, so the plugin must not redraw. One letter (no
    #     Return) typed into foot, only after checking that foot has the keyboard and the session is not locked.
    active=$(nestctl -j activewindow | jq -r '.pid // 0')
    lockst=$("$root/tests/visual/ipc.sh" lock status 2>>"$log")
    if [[ $active == "$foot_pid" && $lockst == unlocked ]]; then
      timeout 10 "$root/scripts/dev/keys.sh" a >>"$log" 2>&1
      sleep 0.4
      read -r w h _ _ _ < <(measure "hidden-typed" "$bx" "$by")
      check "foot hid the pointer while typing" "$( ((w == 0)); echo $?)" "drawn ${w}x${h}"
      set_size 48 || true
      nestctl dispatch 'hl.plugin.grassfield.cursor_refresh()' >>"$log" 2>&1
      sleep 0.3
      read -r w h _ _ _ < <(measure "hidden-after-refresh" "$bx" "$by")
      check "a refresh never shows a hidden pointer" "$( ((w == 0)); echo $?)" "drawn ${w}x${h} after the 48 px size and a refresh"
      pointer abs $((bx + 1)) "$by" sleep 50 # a user's motion shows it again (foot sets the shape)
      sleep 0.4
      read -r w h _ _ _ < <(measure "shown-again-48" "$bx" "$by")
      q=$(ratio "$h" "${seq_h24[ibeam]:-0}")
      check "shown again by a motion: I-beam at the size applied while hidden" "$(within "$q" 1.6 2.4; echo $?)" "drawn ${w}x${h} = ${q} x the 24 px height"
      start_at_24
    else
      check "hidden pointer case: foot has the keyboard and the session is unlocked" 1 "active pid $active (foot $foot_pid), lock $lockst: nothing typed"
    fi
    kill "$foot_pid" 2>/dev/null
    foot_pid=""
    sleep 0.5
  fi

  # 3. Rate: 10 refreshes per second for 3 s (the shell's slider rate in the brief), then 1000 calls in one dispatch.
  reference rate "$ax" "$ay" || check "rate: reference capture" 1 "shot failed"
  pointer abs "$ax" "$ay" sleep 50
  sleep 0.6
  set_size 48 || true
  read -r w0 h0 _ _ _ < <(measure "rate-before" "$ax" "$ay")
  for _ in $(seq 1 30); do
    nestctl dispatch 'hl.plugin.grassfield.cursor_refresh()' >>"$log" 2>&1
    sleep 0.1
  done
  nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.cursor_refresh then for i = 1, 1000 do p.cursor_refresh() end end end" >>"$log" 2>&1
  sleep 0.3
  read -r w1 h1 _ _ _ < <(measure "rate-after" "$ax" "$ay")
  kill -0 "$hypr_pid" 2>/dev/null
  check "30 calls at 10/s and a flood of 1000: Hyprland alive" $? "pid $hypr_pid"
  check "after the flood: same pointer image" "$([[ "${w1}x${h1}" == "${w0}x${h0}" && $w1 -gt 0 ]]; echo $?)" "${w1}x${h1} vs ${w0}x${h0}"
  nestctl dispatch 'hl.plugin.grassfield.cursor_refresh("extra", 42)' >>"$log" 2>&1
  check "arguments are ignored (no Lua error)" $? "rc of the dispatch"

  # 4. Unload: no cursor-refresh, the shell sends nothing and the still pointer keeps its size; load: back.
  set_size 24 || true
  nestctl plugin unload "$plugin" >>"$log" 2>&1
  rc=$?
  sleep 0.5
  check "plugin unloaded" "$( ((rc == 0)) && ! has_refresh; echo $?)" "rc $rc, features $(features)"
  read -r _ h24 _ _ _ < <(measure "unloaded-24" "$ax" "$ay")
  set_size 48 || true
  read -r _ h48 _ _ _ < <(measure "unloaded-48" "$ax" "$ay")
  check "without the plugin the still pointer keeps its size" "$(within "$(ratio "$h48" "$h24")" 0.9 1.1; echo $?)" "height $h48 vs $h24"
  nestctl plugin load "$plugin" >>"$log" 2>&1
  rc=$?
  sleep 1
  check "plugin loaded again with cursor-refresh" "$( ((rc == 0)) && has_refresh; echo $?)" "rc $rc, features $(features)"
  set_size 96 || true
  read -r _ h96 _ _ _ < <(measure "reloaded-96" "$ax" "$ay")
  check "after the load the still pointer grows again" "$(within "$(ratio "$h96" "$h24")" 3.2 4.8; echo $?)" "height $h96 vs $h24 at 24"
  set_size 24 || true
fi

kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $? "pid $hypr_pid"
grep -a '\[grassfield\] cursor_refresh' "$dev/hyprland.log" 2>/dev/null | tail -n 5 >>"$log"
if ((fail == 0)); then say "cursor_refresh $mode: PASS"; else say "cursor_refresh $mode: FAIL"; fi
say "cursor_refresh $mode: log $log"
exit "$fail"
