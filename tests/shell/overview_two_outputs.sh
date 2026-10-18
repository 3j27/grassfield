#!/usr/bin/env bash
# Overview keyboard and pointer on TWO outputs (WAYLAND-1 + GF-REF) in the NESTED session. Run it bare, with a nested
# session up (`just nested-up`, or `scripts/dev/nested-up.sh --no-plugin` for the thumbnail variant); it starts two
# foot windows (one per output, through scripts/dev/isolated.sh) and kills only those.
#
#   tests/shell/overview_two_outputs.sh [click|hover|drag|loop|backdrop|all]
#
# click     (1) overview open with B active: a click on A's rect on the other output focuses A and A gets typed keys; reverse.
# hover     (2) hover selects the window under the pointer on both outputs.
# drag      (2) a window dragged to the "+" Space tile of its output, on each output, changes Space.
# loop      (3) 10x open/close, alternating Esc and IPC close, focus alternating between outputs: after each close the
#               previous window is the active one and gets the keys.
# backdrop  (4) a click on empty space of the other output closes the overview.
# Exit 0 when every check passes. Input only through scripts/dev/keys.sh and scripts/dev/pointer.sh.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=$dev/ovt
# scripts/dev/test.sh runs every tests/shell/*.sh: without a running nested session this test is skipped.
# Only this tree's live nested session (records verified by start time; scripts/dev/pidfile.sh); skipped in the sandbox.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP overview_two_outputs: no nested session of this tree (just nested-up, as a bare command)"
  exit 0
fi
mkdir -p "$out"
sock=$DEV_NESTED_SOCK
bus=""
[[ -f $dev/bus.address ]] && bus=$(<"$dev/bus.address")
fails=0
pids=()

# check <name> <exit status of the condition>: always pass the status through `rc=$?` first (a command substitution in
# the name would otherwise overwrite $?).
check() {
  if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi
}
ipc() { "$root/tests/visual/ipc.sh" "$@"; }
ptr() { "$root/scripts/dev/pointer.sh" "$@" >/dev/null; }
status() { ipc overview status; }
active_title() { "$root/scripts/nestctl" activewindow -j | jq -r '.title // ""'; }
active_monitor() { "$root/scripts/nestctl" activewindow -j | jq -r '.monitor // -1'; }
monitor_name() { "$root/scripts/nestctl" monitors -j | jq -r --argjson i "$1" '.[] | select(.id == $i) | .name'; }
wait_for() { # <seconds> cmd...
  local n=$(( $1 * 10 )) i; shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}

spawn_foot() { # <title> <output>
  ptr output "$2" abs 600 400
  sleep 0.5
  : >"$out/$1.txt"
  "$root/scripts/dev/isolated.sh" --name ovt -- env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" \
    foot -c "$root/tests/visual/fixtures/foot.ini" -T "$1" --window-size-chars 50x12 sh -c "cat >> '$out/$1.txt'" \
    >/dev/null 2>&1 </dev/null &
  pids+=("$!")
  sleep 2
}
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

focus() { # <title>: focus a window by title (nested instance only, through nestctl)
  local addr
  addr=$("$root/scripts/nestctl" clients -j | jq -r --arg t "$1" '.[] | select(.title == $t) | .address')
  "$root/scripts/nestctl" dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null
  sleep 0.4
}

# center <title>: "<output> <x> <y>" (output-relative) of the window's surface box in the overview layout.
center() {
  local mons
  mons=$("$root/scripts/nestctl" monitors -j)
  status | jq -r --argjson mons "$mons" --arg t "$1" '
    .screens[] as $s | $s.windows[] | select(.title == $t) as $w
    | ($s.v2Rects[] | select(.address == $w.address)) as $r
    | ($mons[] | select(.name == $s.name)) as $m
    | "\($s.name) \((($r.x + $r.w / 2) - $m.x) | floor) \((($r.y + $r.h / 2) - $m.y) | floor)"' | head -1
}
# center for thumbnails (v1): window-local rect + the output origin and the menu bar height.
center_v1() {
  local mons
  mons=$("$root/scripts/nestctl" monitors -j)
  status | jq -r --argjson mons "$mons" --arg t "$1" '
    .screens[] as $s | $s.windows[] | select(.title == $t) as $w
    | ($mons[] | select(.name == $s.name)) as $m
    | "\($s.name) \(($w.rect.x + $w.rect.w / 2) | floor) \(($w.rect.y + $w.rect.h / 2 + 32) | floor)"' | head -1
}
where() { # <title>
  local c
  c=$(center "$1")
  [[ -n $c ]] || c=$(center_v1 "$1")
  echo "$c"
}

overview_open() { status | jq -e '.open and (.screens | length) > 0' >/dev/null 2>&1; }
overview_closed() { status | jq -e '.open | not' >/dev/null 2>&1; }
overview_ready() { overview_open && status | jq -e '[.screens[] | .progress] | min >= 1' >/dev/null 2>&1; }
open_overview() {
  ipc overview open >/dev/null
  wait_for 5 overview_ready
  sleep 1.2
}
type_into() { # <title>: type a line, expect it in the window's file
  local t=$1 tag=$2
  sleep 0.4   # keyboard enter after the close
  "$root/scripts/dev/keys.sh" "$tag" -k Return
  wait_for 3 grep -q "$tag" "$out/$t.txt" && return 0
  # Diagnostic only (the check still fails): were the keys lost, or is the window not receiving at all?
  "$root/scripts/dev/keys.sh" "R$tag" -k Return
  if wait_for 3 grep -q "R$tag" "$out/$t.txt"; then echo "note: $t: first typing lost, second arrived; active=$(active_title)"; else echo "note: $t: second typing lost too; active=$(active_title)"; fi
  return 1
}
click_on() { # <title>
  local c o x y
  c=$(where "$1")
  read -r o x y <<<"$c"
  ptr output "$o" abs "$x" "$y" sleep 400
  ptr output "$o" abs $((x + 2)) $((y + 2)) sleep 300 click
}

setup() {
  spawn_foot A WAYLAND-1
  spawn_foot B GF-REF
  "$root/scripts/nestctl" clients -j | jq -c '.[] | select(.title == "A" or .title == "B") | {title, mon: .monitor, ws: .workspace.id}'
}

t_click() {
  local first second act
  for pair in "B A" "A B"; do
    read -r first second <<<"$pair"
    focus "$first"
    open_overview
    click_on "$second"
    wait_for 5 overview_closed
    sleep 0.6
    act=$(active_title)
    [[ $act == "$second" ]]; check "click: click on $second (other output) focuses it (active=$act)" $?
    type_into "$second" "k-$first-$second-$RANDOM"; check "click: $second receives typed keys" $?
  done
}

t_hover() {
  local t c o x y sel addr
  focus A
  open_overview
  for t in A B; do
    c=$(where "$t"); read -r o x y <<<"$c"
    ptr output "$o" abs 5 5 sleep 200 abs "$x" "$y" sleep 300 abs $((x + 3)) $((y + 3)) sleep 500
    addr=$(status | jq -r --arg t "$t" '.screens[].windows[] | select(.title == $t) | .address')
    sel=$(status | jq -r --arg n "$o" '.screens[] | select(.name == $n) | .selected')
    [[ -n $addr && $sel == "$addr" ]]; check "hover: pointer over $t on $o selects it (selected=$sel)" $?
  done
  ipc overview close >/dev/null
  wait_for 5 overview_closed
}

# tile_x <output> <index>: output-relative x of the index-th tile of the Spaces bar (the Spaces, then "+"); tiles are 168 px
# wide with a pitch of 181 px, centred on the output.
tile_x() {
  local w n
  w=$(status | jq -r --arg n "$1" '.screens[] | select(.name == $n) | .width')
  n=$(status | jq -r --arg n "$1" '.screens[] | select(.name == $n) | .spaces | length + 1')
  echo $(( w / 2 + (2 * $2 - (n - 1)) * 181 / 2 ))
}
window_space() { "$root/scripts/nestctl" clients -j | jq -r --arg t "$1" '.[] | select(.title == $t) | .workspace.id'; }

move_to_space() { # <title> <workspace id>: without following (nested instance, through nestctl)
  local addr
  addr=$("$root/scripts/nestctl" clients -j | jq -r --arg t "$1" '.[] | select(.title == $t) | .address')
  "$root/scripts/nestctl" dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$addr\" })" >/dev/null
  sleep 0.5
}

# Each output gets a second Space (a spare window C1/C2 parked there); then A and B are dragged to it while the keyboard
# sits on the other output's chrome. The window must change Space.
t_drag() {
  local t other o x y spare tgt before after
  # Known placement whatever the earlier tests left: A and B on their output's own Space, the spares on a second one.
  local wa wb
  wa=$("$root/scripts/nestctl" monitors -j | jq -r '.[] | select(.name == "WAYLAND-1") | .activeWorkspace.id')
  wb=$("$root/scripts/nestctl" monitors -j | jq -r '.[] | select(.name == "GF-REF") | .activeWorkspace.id')
  move_to_space A "$wa"
  move_to_space B "$wb"
  spawn_foot C1 WAYLAND-1
  move_to_space C1 9
  spawn_foot C2 GF-REF
  move_to_space C2 10
  for t in A B; do
    other=$([[ $t == A ]] && echo B || echo A)
    focus "$t"
    open_overview
    read -r o x y <<<"$(where "$t")"
    tgt=$(status | jq -r --arg n "$o" '[.screens[] | select(.name == $n) | .spaces[] | .active] | index(false) // -1')
    [[ $tgt -ge 0 ]] || { check "drag: $o has a second Space tile" 1; continue; }
    before=$(window_space "$t")
    focus "$other"
    ptr output "$o" abs "$x" "$y" sleep 400 down sleep 300 drag "$(tile_x "$o" "$tgt")" 88 sleep 500 up
    sleep 1.5
    after=$(window_space "$t")
    [[ $before != "$after" ]]; check "drag: $t on $o dropped on another Space tile changed Space ($before -> $after)" $?
    ipc overview close >/dev/null
    wait_for 5 overview_closed
    sleep 0.5
  done
}

t_loop() {
  local i from other mode act pre
  for i in $(seq 1 10); do
    if (( i % 2 )); then from=A; other=B; else from=B; other=A; fi
    focus "$from"
    pre=$(active_title)
    open_overview
    if (( i % 4 < 2 )); then
      "$root/scripts/dev/keys.sh" -k Escape; mode=Esc
    else
      ipc overview close >/dev/null; mode=IPC
    fi
    wait_for 5 overview_closed
    sleep 0.7
    act=$(active_title)
    [[ $act == "$from" ]]; check "loop $i ($mode): $from active after close (active=$act, before open=$pre)" $?
    type_into "$from" "L$i-$RANDOM"; check "loop $i: $from receives typed keys" $?
  done
}

t_backdrop() {
  local o
  for o in GF-REF WAYLAND-1; do
    focus "$([[ $o == GF-REF ]] && echo A || echo B)"
    open_overview
    # Bottom-left corner area: no window, no Spaces bar.
    ptr output "$o" abs 6 600 sleep 300 click
    wait_for 5 overview_closed; check "backdrop: click on empty space of $o closes the overview" $?
    sleep 0.5
  done
}

mode=${1:-all}
setup
case $mode in
  click) t_click ;;
  hover) t_hover ;;
  drag) t_drag ;;
  loop) t_loop ;;
  backdrop) t_backdrop ;;
  shots) focus A; open_overview; for o in WAYLAND-1 GF-REF; do "$root/scripts/dev/shot.sh" "ovt-$o" "$o"; done; ipc overview close >/dev/null ;;
  all) t_click; t_hover; t_loop; t_backdrop; t_drag ;;   # drag last: it moves A and B to another Space
  *) echo "usage: $0 [click|hover|drag|loop|backdrop|all]" >&2; exit 2 ;;
esac
exit "$fails"
