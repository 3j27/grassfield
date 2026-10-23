#!/usr/bin/env bash
# Overview keyboard and pointer on TWO HEADLESS outputs (GF-REF + GF-REF2, WAYLAND-1 disabled) in the NESTED session. Run it bare, with a nested
# session up (`just nested-up`, or `scripts/dev/nested-up.sh --no-plugin` for the thumbnail variant); it starts two
# foot windows (one per output, through scripts/dev/isolated.sh) and kills only those.
#
#   tests/shell/overview_two_outputs.sh [click|hover|drag|loop|backdrop|control|clickwins|all]
#
# click     (1) overview open with B active: a click on A's rect on the other output focuses A and A gets typed keys; reverse.
# hover     (2) hover selects the window under the pointer on both outputs.
# drag      (2) a window dragged to the "+" Space tile of its output, on each output, changes Space.
# loop      (3) 10x open/close, alternating Esc and IPC close, focus alternating between outputs, the pointer on the OTHER
#               output: after each close the previous window is the active one and gets the keys.
# arrows    (2b) the window active at open carries the highlight; the first arrow moves to its neighbour on the other output,
#               the opposite arrow returns, Return focuses the selection: it alone gets the typed keys.
# desktop   (3c) a Desktop tile chosen on either output: that Desktop is shown and its window holds the keyboard.
# interrupt (3d) a Desktop switch while open (the plugin ends its overview): same close, the Desktop now shown has the keyboard.
# paths     (3b) every close path (Esc, IPC close, toggle, backdrop click, Apps / Search / the switcher opening through
#               ExclusiveSurfaces), with the
#               pointer on either output and either window active at open: the window active at open holds the KEYBOARD
#               (typed keys arrive in that exact window and in no other).
# control    Apps / Search / the switcher closed by IPC and by Esc, no overview: the window active at open holds the keyboard
#               (pointer on either output, either window active; also run with --no-plugin, C2). Not part of `all`.
# clickwins  the user's click on the other window 0..450 ms after Esc wins over the shell's focus return (10 times).
# backdrop  (4) a click on empty space of the other output closes the overview.
# drop      (5) keys typed D ms after Esc (one injector process, exact delay): never in the wrong window; from 200 ms all
#               arrive in the previously active window. Prints the drop table. Part of `all`.
# Exit 0 when every check passes. Input only through scripts/dev/keys.sh and scripts/dev/pointer.sh.
set -uo pipefail

root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
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
# The helper scripts validate the nested session on every call (pidfile.sh) and, with several agents loading the host,
# that validation sometimes fails transiently before anything is sent: retry such a call (nothing was injected).
retry() { local i; for i in 1 2 3 4 5 6; do "$@" && return 0; sleep 0.4; done; return 1; }
ipc() { retry "$root/tests/visual/ipc.sh" "$@"; }
ptr() { retry "$root/scripts/dev/pointer.sh" "$@" >/dev/null; }
kb() { retry "$root/scripts/dev/keys.sh" "$@"; }
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
cleanup() {
  trap - EXIT
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  # WAYLAND-1 comes back on every exit path: normal end, a failed setup, an abort (the signals below end through exit).
  if [[ ${headless:-} == 1 ]]; then headless_down; fi
}
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM

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
  kb "$tag" -k Return
  wait_for 3 grep -q "$tag" "$out/$t.txt" && return 0
  # Diagnostic only (the check still fails): were the keys lost, or is the window not receiving at all?
  kb "R$tag" -k Return
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

# The measured pair is two HEADLESS outputs of the nested compositor: GF-REF (1920x1080, from config/hypr/dev.lua) and
# GF-REF2 (1440x900, created here and removed at the end, through nestctl only). WAYLAND-1 is the nested compositor's
# window in the owner's session, tiled by the owner's window manager and resized at any time by other agents' sessions:
# it is disabled for the run (and enabled again at the end), so the measured geometry cannot change under the test.
OUT_A=GF-REF
OUT_B=GF-REF2
nc() { "$root/scripts/nestctl" "$@"; }
mon_sizes() { nc monitors -j | jq -r '[.[] | "\(.name)=\(.width)x\(.height)"] | sort | join(" ")'; }
# Lua monitor rule through the nested instance (the call is evaluated by hl.dispatch's argument; its "expected a dispatcher"
# error is harmless: the rule has been applied).
monrule() { nc dispatch "hl.monitor($1)" >/dev/null 2>&1 || true; sleep 0.8; }
headless_up() {
  nc monitors all -j | jq -e --arg n "$OUT_B" 'any(.[]; .name == $n)' >/dev/null || nc output create headless "$OUT_B" >/dev/null
  sleep 0.8
  monrule '{ output = "WAYLAND-1", disabled = true }'
  monrule "{ output = \"$OUT_A\", mode = \"1920x1080@60\", position = \"0x0\", scale = 1 }"
  monrule "{ output = \"$OUT_B\", mode = \"1440x900@60\", position = \"1920x0\", scale = 1 }"
  # The shell creates its per-output surfaces on the new output.
  sleep 2
}
headless_down() {
  local try
  nc output remove "$OUT_B" >/dev/null 2>&1 || true
  # `disabled = false` is what brings WAYLAND-1 back (the rule that disabled it stays in force otherwise).
  for try in 1 2 3; do
    monrule '{ output = "WAYLAND-1", disabled = false, mode = "1440x900", position = "auto", scale = 1 }'
    wayland1_enabled && break
  done
  monrule "{ output = \"$OUT_A\", mode = \"1920x1080@60\", position = \"auto-right\", scale = 1 }"
  wayland1_enabled || echo "WARNING: WAYLAND-1 is still disabled in the nested session (nestctl monitors all)"
}
# True when WAYLAND-1 is in the nested session's active monitor list (a disabled output is not listed there).
wayland1_enabled() { nc monitors -j 2>/dev/null | jq -e 'any(.[]; .name == "WAYLAND-1")' >/dev/null 2>&1; }
size_guard() {
  local now
  now=$(mon_sizes)
  if [[ $now != "$start_sizes" ]]; then echo "INVALID RUN: an output changed size during the run (start: $start_sizes; end: $now): rerun"; fails=1; fi
}

setup() {
  headless=1
  headless_up
  start_sizes=$(mon_sizes)
  echo "outputs: $start_sizes"
  [[ $start_sizes == "$OUT_B=1440x900 $OUT_A=1920x1080" ]] || { echo "INVALID RUN: expected only $OUT_A and $OUT_B, got: $start_sizes"; exit 4; }
  spawn_foot A "$OUT_A"
  spawn_foot B "$OUT_B"
  nc clients -j | jq -c '.[] | select(.title == "A" or .title == "B") | {title, mon: .monitor, ws: .workspace.id}'
  # The Desktops A and B started on (ensure_spares puts them back there).
  HOME_A=$(window_space A)
  HOME_B=$(window_space B)
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
    sleep 0.4
    keys_arrive "$second" "k$first$second$RANDOM"; check "click: $second alone receives typed keys" $?
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

# tile_pos <output> <index>: "x y" (output-relative) of the middle of the index-th Desktop tile (the Desktops, then "+"), as
# the shell lays it out right now (`overview status` tileRects). A copy of the layout constants here went stale (the tiles
# are 138 px wide with a 32 px gap, "+" sits at the right edge) and made every Desktop-tile click miss (audit GF-019).
tile_pos() {
  status | jq -r --arg n "$1" --argjson i "$2" '.screens[] | select(.name == $n) | .tileRects[$i] | "\((.x + .w / 2) | floor) \((.y + (if .plus then .h / 2 else .h * 0.35 end)) | floor)"'
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
  local t other o x y tx ty spare tgt before after
  # Known placement whatever the earlier tests left: A and B on their output's own Space, the spares on a second one.
  ensure_spares
  for t in A B; do
    other=$([[ $t == A ]] && echo B || echo A)
    focus "$t"
    open_overview
    read -r o x y <<<"$(where "$t")"
    tgt=$(status | jq -r --arg n "$o" '[.screens[] | select(.name == $n) | .spaces[] | .active] | index(false) // -1')
    [[ $tgt -ge 0 ]] || { check "drag: $o has a second Space tile" 1; continue; }
    before=$(window_space "$t")
    focus "$other"
    read -r tx ty <<<"$(tile_pos "$o" "$tgt")"
    ptr output "$o" abs "$x" "$y" sleep 400 down sleep 300 drag "$tx" "$ty" sleep 500 up
    sleep 1.5
    after=$(window_space "$t")
    [[ $before != "$after" ]]; check "drag: $t on $o dropped on another Space tile changed Space ($before -> $after)" $?
    ipc overview close >/dev/null
    wait_for 5 overview_closed
    sleep 0.5
  done
}

# ptr_on <title>: park the pointer on the output of the foot window <title> (an empty spot of it: no focus change expected).
out_of() { [[ $1 == A ]] && echo $OUT_A || echo $OUT_B; }
park="700 120"   # a bare spot of an output: no window, no Dock tile, no hot corner
ptr_on() { ptr output "$(out_of "$1")" abs $park; sleep 0.3; }

# keys_arrive <title> <tag>: type <tag> + Return and check it arrived in the window <title> and in no other one: the
# KEYBOARD (not activewindow) is what is verified. Prints where it went when it did not.
keys_arrive() {
  local t=$1 tag=$2 where
  kb "$tag" -k Return
  if ! wait_for 3 grep -qx "$tag" "$out/$t.txt"; then
    where=$(grep -lx "$tag" "$out"/*.txt 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
    echo "note: '$tag' did not reach $t (went to: ${where:-nowhere}; active=$(active_title))"
    return 1
  fi
  ! grep -lx "$tag" "$out"/*.txt | grep -qv "/$t.txt"
}

# close_via <path> <output>: closes the open overview by one path. esc | ipc | toggle | backdrop (click on empty space of
# <output>) | apps (the Apps launcher opens, which closes the overview through ExclusiveSurfaces; then it is closed too).
close_via() {
  local path=$1 o=$2 h
  case $path in
    esc) kb -k Escape ;;
    ipc) ipc overview close >/dev/null ;;
    toggle) ipc overview toggle >/dev/null ;;
    backdrop)
      h=$(status | jq -r --arg n "$o" '.screens[] | select(.name == $n) | .height')
      ptr output "$o" abs 6 $(( h > 200 ? h - 60 : 100 )) sleep 300 click ;;
    apps) ipc apps open >/dev/null; sleep 1; ipc apps close >/dev/null; sleep 0.8 ;;
    search) ipc search open "" >/dev/null; sleep 1; ipc search close >/dev/null; sleep 0.8 ;;
    switcher) ipc switcher next t >/dev/null; sleep 1; ipc switcher cancel >/dev/null; sleep 0.8 ;;
  esac
  wait_for 5 overview_closed
}

# paths: after every close path, with the pointer on either output and either window previously active, the window
# that was active when the overview opened (captured at open) holds the keyboard.
t_paths() {
  local path prev o pre tag n=0
  for path in esc ipc toggle backdrop apps search switcher; do
    for prev in A B; do
      for o in $OUT_A $OUT_B; do
        n=$((n + 1))
        focus "$prev"
        ptr output "$o" abs $park; sleep 0.3
        pre=$(active_title)
        open_overview
        close_via "$path" "$o"
        sleep 0.5
        tag="P$n$RANDOM"
        keys_arrive "$prev" "$tag"; check "paths: $path, pointer on $o, $prev active at open (was $pre): $prev holds the keyboard" $?
      done
    done
  done
}

# control: the same Apps / Search / switcher round trip WITHOUT the overview (what the paths above would give if the overview
# had nothing to do with it): after the surface closes, which window holds the keyboard. Each surface is closed by its IPC
# close and by Esc typed into it (the path a user takes); the key must arrive in the window that was active when the surface
# opened and in no other.
t_control() {
  local path prev o n=0
  for path in apps search switcher apps-esc search-esc switcher-esc; do
    for prev in A B; do
      for o in $OUT_A $OUT_B; do
        n=$((n + 1))
        focus "$prev"
        ptr output "$o" abs $park; sleep 0.3
        close_via_surface "$path"
        sleep 0.5
        keys_arrive "$prev" "C$n$RANDOM"; check "control (no overview): $path, pointer on $o, $prev active: $prev holds the keyboard" $?
      done
    done
  done
}
close_via_surface() {
  case $1 in
    apps) ipc apps open >/dev/null; sleep 1; ipc apps close >/dev/null; sleep 0.8 ;;
    search) ipc search open "" >/dev/null; sleep 1; ipc search close >/dev/null; sleep 0.8 ;;
    switcher) ipc switcher next t >/dev/null; sleep 1; ipc switcher cancel >/dev/null; sleep 0.8 ;;
    apps-esc) ipc apps open >/dev/null; sleep 1; kb -k Escape; sleep 0.8 ;;
    search-esc) ipc search open "" >/dev/null; sleep 1; kb -k Escape; sleep 0.8 ;;
    switcher-esc) ipc switcher next t >/dev/null; sleep 1; kb -k Escape; sleep 0.8 ;;
  esac
}

# clickwins: the user's click wins over the shell's focus return (C2 retry or the plugin request). A is active, the pointer
# rests on B's output; the overview opens and closes with Esc (the focus goes back to A); 400 + D ms after it reports closed
# (D = 0 .. 450, ten values; the shell's focus return is bounded by 1 s) a click on B must leave B active and B alone must get
# the keys. Both the plugin request and the C2 retry check at the moment they run; the shell log says how each one ended.
t_clickwins() {
  local i d act tag px py geo
  # The centre of B's window, relative to its output (the click must land on the window itself, which is small).
  geo=$(nc clients -j | jq -r --arg t B --argjson mons "$(nc monitors -j)" '.[] | select(.title == $t) as $w | ($mons[] | select(.id == $w.monitor)) as $m | "\((($w.at[0] + $w.size[0] / 2) - $m.x) | floor) \((($w.at[1] + $w.size[1] / 2) - $m.y) | floor)"' | head -1)
  read -r px py <<<"$geo"
  [[ -n $px ]] || { check "clickwins: B's window centre found" 1; return; }
  for i in 0 1 2 3 4 5 6 7 8 9; do
    d=$((i * 50))
    focus A
    ptr output $OUT_B abs $park; sleep 0.3
    open_overview
    kb -k Escape
    wait_for 5 overview_closed
    # The chrome keeps its input mask for the zoom-out (overview.motion.slow, 350 ms): a click earlier than that is the chrome's
    # (measured: clicks up to ~200 ms after the close are taken by it, from ~250 ms they reach B), not the focus return's.
    sleep 0.4
    ptr output $OUT_B abs $((px + 1)) $((py + 1)) sleep "$d" click
    sleep 1.2
    act=$(active_title)
    tag="W$i$RANDOM"
    keys_arrive B "$tag"; check "clickwins: click on B 400+${d} ms after the close wins (active=$act): B alone gets the keys" $?
  done
}

# selected_title: title of the window the overview shows as selected (any output), "" for none.
selected_title() {
  status | jq -r '[.screens[] | .selected as $s | .windows[] | select($s != "" and .address == $s) | .title] | first // ""'
}

# arrows (App Exposé model, docs/specs/overview.md): the window active at open carries the highlight; the first arrow key
# moves from it to its neighbour (the window on the output lying that way; the holder chrome may be on the other output),
# the next one stays on the last output's window, the opposite arrow returns to the first window, Return focuses the
# selection, which alone gets the typed keys.
t_arrows() {
  local first second dir back n=0 sel marked
  for pair in "A B Right Left" "B A Left Right"; do
    read -r first second dir back <<<"$pair"
    for o in $OUT_A $OUT_B; do
      n=$((n + 1))
      focus "$first"
      ptr output "$o" abs $park; sleep 0.3
      open_overview
      marked=$(status | jq -r '[.screens[] | .marked as $m | .windows[] | select($m != "" and .address == $m) | .title] | first // ""')
      [[ $marked == "$first" ]]; check "arrows: pointer on $o, $first active at open: it carries the highlight (marked=$marked)" $?
      [[ -z $(selected_title) ]]; check "arrows: nothing is selected before the first key (selected=$(selected_title))" $?
      kb -k "$dir"
      sleep 0.4
      sel=$(selected_title)
      [[ $sel == "$second" ]]; check "arrows: first $dir moves from $first to its neighbour $second (selected=$sel)" $?
      kb -k "$dir"
      sleep 0.4
      sel=$(selected_title)
      [[ $sel == "$second" ]]; check "arrows: $dir past the last output stays on $second (selected=$sel)" $?
      kb -k "$back"
      sleep 0.4
      sel=$(selected_title)
      [[ $sel == "$first" ]]; check "arrows: $back returns to $first (selected=$sel)" $?
      kb -k "$dir"
      sleep 0.4
      kb -k Return
      wait_for 5 overview_closed
      sleep 0.6
      keys_arrive "$second" "R$n$RANDOM"; check "arrows: Return on $second: $second holds the keyboard, no other window" $?
    done
  done
}

# spares: a known layout whatever the earlier tests left (they move windows between Desktops, and Hyprland moves Desktops
# between outputs): every foot window is closed and made again. A (and B) on a new empty Desktop of GF-REF (GF-REF2), C1 on
# Desktop 9 of GF-REF and C2 on Desktop 10 of GF-REF2 (a Desktop other than the shown one on each output).
spare_ws() { window_space "$1"; }
no_test_windows() { ! nc clients -j | jq -e 'any(.[]; .title == "A" or .title == "B" or .title == "C1" or .title == "C2")' >/dev/null; }
ensure_spares() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  pids=()
  wait_for 8 no_test_windows || { echo "INVALID RUN: the test windows did not close"; exit 4; }
  ptr output $OUT_A abs 600 400; sleep 0.4
  nc dispatch 'hl.dsp.focus({ workspace = "21" })' >/dev/null; sleep 0.4
  spawn_foot A $OUT_A
  ptr output $OUT_B abs 600 400; sleep 0.4
  nc dispatch 'hl.dsp.focus({ workspace = "22" })' >/dev/null; sleep 0.4
  spawn_foot B $OUT_B
  # Each spare is moved right after it was spawned: a Desktop created by the move belongs to the output focused then.
  spawn_foot C1 $OUT_A
  move_to_space C1 9
  spawn_foot C2 $OUT_B
  move_to_space C2 10
  focus A
  focus B
  nc clients -j | jq -c '.[] | select(.title | test("^(A|B|C1|C2)$")) | {title, mon: .monitor, ws: .workspace.id}'
}

# desktop: a Desktop tile chosen with the pointer: that Desktop is shown and its window holds the keyboard, whichever
# window was active at open.
t_desktop() {
  local prev tgt o ws idx x y n=0
  ensure_spares
  for prev in A B; do
    for tgt in C1 C2; do
      n=$((n + 1))
      o=$([[ $tgt == C1 ]] && echo $OUT_A || echo $OUT_B)
      ws=$(spare_ws "$tgt")
      focus "$prev"
      ptr output "$o" abs $park; sleep 0.3
      open_overview
      idx=$(status | jq -r --arg n "$o" --argjson ws "$ws" '[.screens[] | select(.name == $n) | .spaces[] | .id] | index($ws) // -1')
      if [[ $idx -lt 0 ]]; then check "desktop: $o shows a tile for Desktop $ws" 1; ipc overview close >/dev/null; wait_for 5 overview_closed; continue; fi
      read -r x y <<<"$(tile_pos "$o" "$idx")"
      ptr output "$o" abs "$x" "$y" sleep 400 click
      wait_for 5 overview_closed
      sleep 0.6
      keys_arrive "$tgt" "D$n$RANDOM"; check "desktop: tile $ws on $o chosen, $prev active at open: $tgt holds the keyboard" $?
      [[ $(nc monitors -j | jq -r --arg n "$o" '.[] | select(.name == $n) | .activeWorkspace.id') == "$ws" ]]; check "desktop: Desktop $ws is shown on $o" $?
    done
  done
  focus A
  focus B
}

# interrupt: the Desktop is switched while the overview is open (the plugin ends its overview: `interrupted`; the shell closes
# through the same path): no stuck chrome, and the keyboard is never lost. A Desktop on the output of the window active at
# open: its window gets the keyboard. A Desktop on the other output: Hyprland keeps the monitor focus where it was, so the
# window it names active gets the keyboard (still never nothing).
t_interrupt() {
  local prev tgt ws n=0 want
  ensure_spares
  # Without the plugin (C2) nothing ends the overview on a Desktop switch: the thumbnails overview stays open, as designed.
  focus A
  open_overview
  if status | jq -e '.thumbnailMode' >/dev/null; then
    echo "SKIP interrupt: no compositor overview (thumbnail mode, no plugin): nothing ends the overview on a Desktop switch"
    ipc overview close >/dev/null
    wait_for 5 overview_closed
    return 0
  fi
  ipc overview close >/dev/null
  wait_for 5 overview_closed
  for prev in A B; do
    for tgt in C1 C2; do
      n=$((n + 1))
      ws=$(spare_ws "$tgt")
      focus "$prev"
      ptr output "$(out_of "$prev")" abs $park; sleep 0.3
      open_overview
      nc dispatch "hl.dsp.focus({ workspace = \"$ws\" })" >/dev/null
      wait_for 5 overview_closed; check "interrupt: a switch to Desktop $ws closes the overview ($prev active at open)" $?
      sleep 0.8
      if [[ $(out_of "$prev") == "$([[ $tgt == C1 ]] && echo $OUT_A || echo $OUT_B)" ]]; then want=$tgt; else want=$(active_title); fi
      echo "note: after the switch: $(nc monitors -j | jq -r '[.[] | "\(.name)=ws\(.activeWorkspace.id)"] | join(" ")') focused=$(nc monitors -j | jq -r '.[] | select(.focused) | .name') active=$(active_title) expected=$want"
      [[ -n $want ]]; check "interrupt: Desktop $ws, $prev active at open: Hyprland names an active window" $?
      keys_arrive "$want" "I$n$RANDOM"; check "interrupt: Desktop $ws shown: $want holds the keyboard" $?
      focus A
      focus B
    done
  done
}

t_loop() {
  local i from other mode act pre tag
  for i in $(seq 1 10); do
    if (( i % 2 )); then from=A; other=B; else from=B; other=A; fi
    focus "$from"
    ptr_on "$other"   # the pointer rests on the OTHER output
    pre=$(active_title)
    open_overview
    if (( i % 4 < 2 )); then
      kb -k Escape; mode=Esc
    else
      ipc overview close >/dev/null; mode=IPC
    fi
    wait_for 5 overview_closed
    sleep 0.7
    act=$(active_title)
    [[ $act == "$from" ]]; check "loop $i ($mode, pointer on $other's output): $from active after close (active=$act, before open=$pre)" $?
    tag="L$i$RANDOM"
    keys_arrive "$from" "$tag"; check "loop $i: $from receives typed keys" $?
  done
}

# drop: Esc closes the overview, one injector process types a tag + Return D ms later (keys.sh -k Escape -s D tag: a single
# connected process, so the delay is exactly D, without the tool's start-up time). 10 tries per delay; the previously active
# window (A or B alternating, the pointer alternating between the outputs) must get the keys: no key may reach the other
# window at any delay, and from 200 ms every key must arrive. Faster keys meet the chrome still holding the keyboard (it
# commits None, then the focus follows): they are lost, never misdelivered. Prints the drop table.
t_drop() {
  local d i ok wrong lost prev o tag
  for d in 0 30 60 100 150 200 300; do
    ok=0 wrong=0 lost=0
    for i in $(seq 1 10); do
      if (( i % 2 )); then prev=A; else prev=B; fi
      if (( i % 4 < 2 )); then o=$(out_of "$prev"); else o=$([[ $prev == A ]] && echo $OUT_B || echo $OUT_A); fi
      focus "$prev"
      ptr output "$o" abs $park; sleep 0.3
      open_overview
      tag="d${d}i${i}r$RANDOM"
      if (( d > 0 )); then
        kb -k Escape -s "$d" "$tag" -k Return
      else
        kb -k Escape "$tag" -k Return
      fi
      sleep 0.7
      if grep -qx "$tag" "$out/$prev.txt"; then
        ok=$((ok + 1))
      elif grep -lx "$tag" "$out"/*.txt >/dev/null 2>&1; then
        wrong=$((wrong + 1))
      else
        lost=$((lost + 1))
      fi
      wait_for 3 overview_closed
      sleep 0.4
    done
    echo "drop table: ${d} ms after Esc: $ok/10 in the previous window, $lost lost, $wrong in another window"
    check "drop: ${d} ms after Esc no key reaches another window ($wrong)" $(( wrong == 0 ? 0 : 1 ))
    if (( d >= 200 )); then
      check "drop: ${d} ms after Esc every key reaches the previously active window ($ok/10)" $(( ok == 10 ? 0 : 1 ))
    fi
  done
}

t_backdrop() {
  local o
  for o in $OUT_B $OUT_A; do
    focus "$([[ $o == $OUT_B ]] && echo A || echo B)"
    open_overview
    # Bottom-left corner area: no window, no Spaces bar.
    ptr output "$o" abs 6 600 sleep 300 click
    wait_for 5 overview_closed; check "backdrop: click on empty space of $o closes the overview" $?
    sleep 0.5
  done
}

mode=${1:-all}
[[ $mode == lib ]] && return 0   # sourced by a probe script: functions only
setup
case $mode in
  click) t_click ;;
  hover) t_hover ;;
  drag) t_drag ;;
  loop) t_loop ;;
  backdrop) t_backdrop ;;
  drop) t_drop ;;
  shots) focus A; open_overview; for o in $OUT_A $OUT_B; do "$root/scripts/dev/shot.sh" "ovt-$o" "$o"; done; ipc overview close >/dev/null ;;
  paths) t_paths ;;
  control) t_control ;;
  clickwins) t_clickwins ;;
  arrows) t_arrows ;;
  desktop) t_desktop ;;
  interrupt) t_interrupt ;;
  # drag, desktop and interrupt last: they move windows to other Spaces (ensure_spares puts A and B back first)
  all) t_click; t_hover; t_arrows; t_loop; t_paths; t_clickwins; t_backdrop; t_drop; t_drag; t_desktop; t_interrupt ;;
  *) echo "usage: $0 [click|hover|arrows|drag|loop|paths|control|clickwins|backdrop|drop|desktop|interrupt|all]" >&2; exit 2 ;;
esac
size_guard
exit "$fails"
