#!/usr/bin/env bash
# Dock attention requests on the nested output (macOS: an app that needs attention bounces its icon until it is activated).
# A test client asks for attention by printing BEL after a delay (foot with `-o bell.urgent=yes`), while another window has the
# focus; Hyprland then emits `urgent>>ADDRESS`, which the platform layer relays (Compositor.attention) to the Dock. Observed through
# the shell log (`dock-attention:` lines, fixtures only), like dock-launch.sh's `lift` lines.
#   bounce   the icon of the unfocused app hops repeatedly (lift lines: several hops, each about a third of the icon), the
#            focused app's icon does not; focusing a window of the app stops it (settled line, lift back to 0)
#   focused  BEL from the window that has the focus: no bounce (nothing is logged as a bounce)
#   autohide an auto-hidden Dock comes out for a moment (dock.attentionReveal) and hides again afterwards
#   toggle   IPC dock toggleAutohide flips auto-hide (Option-Command-D equivalent)
#   reduced  Reduce Motion on: no hop (no lift line), the tile is still marked (screenshot crop attention-reduced.png)
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-attention.sh [part ...]     all parts by default
# Output: .dev/visual/dock-attention/. Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

out=$VS_STATE/dock-attention
was_running=0
vs_nested_running && was_running=1
nest() { "$VS_ROOT/scripts/nestctl" "$@"; }
cleanup() {
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

parts=("$@")
(( ${#parts[@]} )) || parts=(bounce focused autohide toggle reduced)
want() { local p; for p in "${parts[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

mkdir -p "$out"
rm -f "$out"/*
passed=0
failed=0
check() { # DESCRIPTION CONDITION-EXIT-STATUS
  if [[ $2 -eq 0 ]]; then echo "PASS $1"; passed=$((passed + 1)); else echo "FAIL $1"; failed=$((failed + 1)); fi
}
count_class() { nest clients -j | jq --arg c "$1" '[.[] | select(.class == $c)] | length'; }
addr_of() { nest clients -j | jq -r --arg c "$1" '[.[] | select(.class == $c)][0].address // ""'; }
wait_count() { # CLASS N SECONDS
  local i
  for i in $(seq 1 $(( $3 * 4 ))); do
    [[ $(count_class "$1") -eq $2 ]] && return 0
    sleep 0.25
  done
  return 1
}
focus() { nest dispatch "hl.dsp.focus({window = 'address:$(addr_of "$1")'})" >/dev/null 2>&1; sleep 0.6; }
# A foot window that prints BEL after $2 seconds and asks for attention while unfocused. CLASS DELAY
bell_client() {
  vs_spawn foot --app-id "$1" -o bell.urgent=yes sh -c "sleep $2; printf '\\a'; exec sleep 100000"
}
plain_client() { vs_spawn foot --app-id "$1" sh -c "exec sleep 100000"; }
shell_mark() { wc -l < "$VS_DEV/shell.log"; }
log_since() { tail -n +"$(( $1 + 1 ))" "$VS_DEV/shell.log" | grep "dock-attention:"; }
lifts() { grep -c "dock-attention: lift" <<<"$1"; }
# Number of separate hops in the lift lines: a hop starts when the lift rises from 0.
hops() { awk '/dock-attention: lift/ {v = $NF; if (v > 0 && prev == 0) n++; prev = v} END {print n + 0}' <<<"$1"; }
peak() { awk '/dock-attention: lift/ {if ($NF > m) m = $NF} END {print m + 0}' <<<"$1"; }

vs_session en
vs_reset dark 0.25
vs_ipc dock magnify 1 false >/dev/null
vs_ipc dock autohide false >/dev/null
vs_ipc controlcenter reduceMotion false >/dev/null

# The window that asks must not have the focus when it does: the plain client is mapped last and keeps it.
start_pair() { # CLASS DELAY: a bell client, then a plain client that has the focus
  bell_client "$1" "$2"
  wait_count "$1" 1 10 || { echo "dock-attention: $1 did not start"; return 1; }
  plain_client gfAfront
  wait_count gfAfront 1 10 || { echo "dock-attention: gfAfront did not start"; return 1; }
  sleep 0.5
}
stop_all() { vs_kill_clients; vs_ipc dock unhover >/dev/null; sleep 1; }

if want bounce; then
  stop_all
  mark=$(shell_mark)
  start_pair gfAask 3 || exit 1
  [[ $(nest activewindow -j | jq -r '.class') == gfAfront ]]; check "bounce: the plain client has the focus when the bell rings" $?
  sleep 8
  log=$(log_since "$mark")
  echo "$log" > "$out/bounce.log"
  grep -q "dock-attention: urgent .* bounce" <<<"$log"; check "bounce: Hyprland's urgent event reached the Dock and started a bounce" $?
  h=$(hops "$log")
  [[ $h -ge 3 ]]; check "bounce: the icon hops again and again ($h hops in 8 s)" $?
  p=$(peak "$log")
  awk -v p="$p" 'BEGIN {exit !(p > 8)}'; check "bounce: a hop rises ($p px)" $?
  keys=$(vs_ipc dock tiles)
  echo "tiles $keys" >> "$out/bounce.log"
  mark=$(shell_mark)
  focus gfAask
  sleep 2
  log=$(log_since "$mark")
  echo "$log" >> "$out/bounce.log"
  grep -q "dock-attention: settled 0" <<<"$log"; check "bounce: focusing the app stopped the bounce (settled 0)" $?
  mark=$(shell_mark)
  sleep 3
  [[ $(lifts "$(log_since "$mark")") -eq 0 ]]; check "bounce: no hop after the app was activated" $?
fi

if want focused; then
  stop_all
  mark=$(shell_mark)
  bell_client gfAself 3
  wait_count gfAself 1 10 || exit 1
  sleep 5
  log=$(log_since "$mark")
  echo "$log" > "$out/focused.log"
  ! grep -q "dock-attention: urgent .* bounce" <<<"$log"; check "focused: a bell from the focused window does not bounce" $?
  [[ $(lifts "$log") -eq 0 ]]; check "focused: no hop" $?
fi

if want autohide; then
  stop_all
  vs_ipc dock autohide true >/dev/null
  sleep 2
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  [[ $s == hidden* ]]; check "autohide: the Dock is hidden before the request ($s)" $?
  start_pair gfAask 3 || exit 1
  sleep 3.6
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  echo "after request: $s" > "$out/autohide.log"
  [[ $s == revealing* || $s == shown* ]]; check "autohide: the Dock came out for the request ($s)" $?
  sleep 6
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  echo "later: $s" >> "$out/autohide.log"
  [[ $s == hid* ]]; check "autohide: the Dock went away again after attentionReveal ($s)" $?
  vs_ipc dock autohide false >/dev/null
fi

# IPC `dock toggleAutohide` (Option-Command-D): not fixtures-gated, flips dock.autohide each call.
if want toggle; then
  stop_all
  vs_ipc dock autohide false >/dev/null
  sleep 1
  vs_ipc dock toggleAutohide >/dev/null
  sleep 2.5
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  [[ $s == hidden* ]]; check "toggle: toggleAutohide turned hiding on, the Dock hides ($s)" $?
  vs_ipc dock toggleAutohide >/dev/null
  sleep 1.5
  s=$(vs_ipc dock hidestate "$VS_OUTPUT")
  [[ $s == shown* ]]; check "toggle: a second toggleAutohide turned it off, the Dock is shown ($s)" $?
fi

if want reduced; then
  stop_all
  vs_ipc controlcenter reduceMotion true >/dev/null
  mark=$(shell_mark)
  start_pair gfAask 3 || exit 1
  sleep 6
  log=$(log_since "$mark")
  echo "$log" > "$out/reduced.log"
  grep -q "dock-attention: urgent .* bounce" <<<"$log"; check "reduced: the request is registered" $?
  [[ $(lifts "$log") -eq 0 ]]; check "reduced: no hop with Reduce Motion" $?
  "$VS_ROOT/scripts/dev/shot.sh" dock-attention-reduced "$VS_OUTPUT" >/dev/null
  cp "$VS_DEV/shots/dock-attention-reduced.png" "$out/attention-reduced.png"
  magick "$out/attention-reduced.png" -crop 700x140+610+940 +repage "$out/attention-reduced-crop.png"
  vs_ipc controlcenter reduceMotion false >/dev/null
fi

echo "dock-attention: $passed passed, $failed failed (logs and captures in $out)"
(( failed == 0 ))
