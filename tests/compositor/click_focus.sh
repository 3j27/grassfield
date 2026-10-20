#!/usr/bin/env bash
# Click-to-focus scenario (macOS model): a press anywhere on a window that does not hold the keyboard (its content or
# its titlebar) makes it the key window, brings it to the front, and the keys typed next reach it.
#
# Usage: tests/compositor/click_focus.sh [explore]
# NESTED only, run BARE: needs this tree's nested session (scripts/dev/nested-up.sh) with the real shell.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${CF_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID

for tool in jq foot socat; do
  command -v "$tool" >/dev/null || { echo "click_focus: $tool not installed" >&2; exit 2; }
done

run=$dev/click-focus/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
hyprlog=${XDG_RUNTIME_DIR:?}/hypr/$sig/hyprland.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
ms() { sleep "$(awk -v m="$1" 'BEGIN { printf "%.3f", m / 1000 }')"; }

pids=()
socat_pid=""
headless=0
# Lua monitor rule through the nested instance (hl.dispatch's "expected a dispatcher" error is harmless: the rule applied).
monrule() { nestctl dispatch "hl.monitor($1)" >/dev/null 2>&1 || true; sleep 0.8; }
wayland1_enabled() { nestctl monitors -j 2>/dev/null | jq -e 'any(.[]; .name == "WAYLAND-1")' >/dev/null 2>&1; }
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  if ((headless)); then
    for _ in 1 2 3; do
      monrule '{ output = "WAYLAND-1", disabled = false, mode = "1440x900", position = "auto", scale = 1 }'
      wayland1_enabled && break
    done
    monrule '{ output = "GF-REF", mode = "1920x1080@60", position = "auto-right", scale = 1 }'
    wayland1_enabled || echo "WARNING: WAYLAND-1 is still disabled in the nested session" >&2
  fi
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM
# --headless: WAYLAND-1 (the nested window, paced by the owner's session) is disabled for the run, so that every shell
# surface is paced by the nested Hyprland itself, as on real outputs.
if [[ ${CF_HEADLESS:-0} == 1 || " $* " == *" --headless "* ]]; then
  headless=1
  monrule '{ output = "WAYLAND-1", disabled = true }'
  monrule '{ output = "GF-REF", mode = "1920x1080@60", position = "0x0", scale = 1 }'
  sleep 2
fi
socat -u UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null >"$events" &
socat_pid=$!

read -r mon_x mon_y mon_w mon_h < <(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "click_focus: output $out not found" >&2; exit 2; }

probe() { # <capture> <title> -> pid; every typed byte goes to <capture>
  : >"$1"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name click-focus foot --title "$2" -w 640x400 \
    -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$1" >/dev/null 2>&1 </dev/null &
  echo $!
}
address_of() { # <pid>
  local a="" i
  for i in $(seq 1 50); do
    a=$(nestctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p and .mapped)][0].address // ""')
    [[ -n $a ]] && break
    ms 100
  done
  echo "$a"
}
geom() { # <address> -> x y w h relative to the output
  nestctl -j clients | jq -r --arg a "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.address == $a) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"'
}
active() { nestctl -j activewindow 2>/dev/null | jq -r '.address // "none"'; }
name_of() {
  case $1 in
    "$win_a") echo A ;; "$win_b") echo B ;; none | "") echo none ;; *) echo "other($1)" ;;
  esac
}

cap_a=$run/a.cap cap_b=$run/b.cap
mark_a=0 mark_b=0
mark() { mark_a=$(stat -c %s "$cap_a"); mark_b=$(stat -c %s "$cap_b"); }
cap_new() { tail -c +"$(($2 + 1))" "$1" | tr -d '\n'; }
# Types <letters> and reports where they went: "A=<..> B=<..> active=<A|B|none>".
type_now() {
  mark
  keys "$1"
  ms 400
  printf 'A=%s B=%s active=%s' "$(cap_new "$cap_a" "$mark_a")" "$(cap_new "$cap_b" "$mark_b")" "$(name_of "$(active)")"
}
click() { pointer abs "$1" "$2" sleep 150 click; }
hyprmark=0
hmark() { hyprmark=$(grep -ac "" "$hyprlog"); }
htrace() { tail -n +"$((hyprmark + 1))" "$hyprlog" | grep -a -i -E "focus|refus|grassfield\]" | head -n 40 >>"$log"; }

say "click_focus: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), $out ${mon_w}x${mon_h}"
say "plugin: $(nestctl -j grassfield 2>/dev/null | jq -c .features 2>/dev/null || echo none)"

pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 50
p=$(probe "$cap_a" gf-click-a); pids+=("$p"); win_a=$(address_of "$p")
p=$(probe "$cap_b" gf-click-b); pids+=("$p"); win_b=$(address_of "$p")
[[ -n $win_a && -n $win_b ]] || { say "setup error: probes did not map"; exit 2; }
nestctl dispatch "hl.dsp.window.move({ x = $((mon_x + 120)), y = $((mon_y + 160)), window = 'address:$win_a' })" >>"$log" 2>&1
nestctl dispatch "hl.dsp.window.move({ x = $((mon_x + 1000)), y = $((mon_y + 160)), window = 'address:$win_b' })" >>"$log" 2>&1
ms 800
read -r ax ay aw ah < <(geom "$win_a")
read -r bx by bw bh < <(geom "$win_b")
say "A $win_a ${aw}x${ah}+$ax+$ay   B $win_b ${bw}x${bh}+$bx+$by"
a_in="$((ax + aw / 2)) $((ay + ah / 2))"
b_in="$((bx + bw / 2)) $((by + bh / 2))"
a_bar="$((ax + aw / 2)) $((ay - 14))"
b_bar="$((bx + bw / 2)) $((by - 14))"

ipc() { timeout 5 "$root/tests/visual/ipc.sh" "$@" >>"$log" 2>&1; }
# Mapped layer namespaces on the output, "-" when none.
layers_on() {
  nestctl -j layers | jq -r --arg o "$out" '.[$o].levels | [.[][] | .namespace] | join(",")'
}
# Polls the mapped layers every 100 ms for <n> rounds, logging every change with its time.
poll_layers() {
  local n=$1 i last="" now
  for ((i = 0; i < n; i++)); do
    now=$(layers_on)
    [[ $now != "$last" ]] && say "    t+$((i * 100))ms layers: $now"
    last=$now
    ms 100
  done
}

# Milliseconds until <namespace> is no longer mapped on the output (polled as fast as hyprctl answers), max 6000.
gone_after() {
  local ns=$1 t0 now
  t0=$(date +%s%3N)
  while :; do
    now=$(date +%s%3N)
    ((now - t0 > 6000)) && { echo "never"; return; }
    nestctl -j layers | jq -e --arg o "$out" --arg n "$ns" '[.[$o].levels[][] | .namespace] | index($n)' >/dev/null || break
  done
  echo $(($(date +%s%3N) - t0))
}

if [[ ${1:-explore} == unmap ]]; then
  click_a() { read -r x y <<<"$a_in"; click "$x" "$y"; ms 300; }
  for round in 1 2 3; do
    click_a
    ipc menubar open system "$out"; ms 600
    keys -k Escape
    say "unmap $round: menu (Escape): overlay gone after $(gone_after grassfield-overlay) ms"
    ms 500
    ipc search toggle; ms 800
    keys -k Escape
    say "unmap $round: Search (Escape): gone after $(gone_after grassfield-search) ms"
    ms 500
    ipc apps toggle; ms 800
    keys -k Escape
    say "unmap $round: Apps (Escape): gone after $(gone_after grassfield-apps) ms"
    ms 500
    ipc notifications toggleCenter; ms 800
    keys -k Escape
    say "unmap $round: Notification Center (Escape): gone after $(gone_after grassfield-notification-center) ms"
    ms 500
  done
  say "layers now: $(layers_on)"
  exit 0
fi

if [[ ${1:-explore} == menubar ]]; then
  for round in 1 2 3 4 5; do
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "round $round: A clicked -> $(type_now x)"
    click 150 12; ms 600
    "$root/scripts/dev/shot.sh" "click-focus-r$round-open" "$out" >>"$log" 2>&1
    click 150 12
    ms 300
    "$root/scripts/dev/shot.sh" "click-focus-r$round-closed" "$out" >>"$log" 2>&1
    poll_layers 15
    say "round $round: bar item clicked twice (open, close) -> $(type_now x)"
    poll_layers 10
    say "round $round: 2 s later -> $(type_now x)"
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "round $round: click A content -> $(type_now x)"
    read -r x y <<<"$b_in"; click "$x" "$y"; ms 400
    say "round $round: click B content -> $(type_now x)"
  done
  exit 0
fi

if [[ ${1:-explore} == barkeys ]]; then
  for round in 1 2 3 4; do
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "round $round: A clicked -> $(type_now x)"
    hmark
    click 150 12; ms 800
    keys -k Escape
    ms 300
    pointer abs 300 12 sleep 100 abs 500 12 # the pointer moves along the bar, as a hand does after Escape
    ms 3000
    say "round $round: menu opened from the bar, Escape, pointer along the bar, 3 s -> $(type_now x)"
    htrace
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "round $round: click A content -> $(type_now x)"
    read -r x y <<<"$a_bar"; click "$x" "$y"; ms 400
    say "round $round: click A titlebar -> $(type_now x)"
    read -r x y <<<"$b_in"; click "$x" "$y"; ms 400
    say "round $round: click B content -> $(type_now x)"
  done
  exit 0
fi

if [[ ${1:-explore} == launch ]]; then
  cap_c=$run/c.cap
  for surface in apps search; do
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "$surface: A clicked -> $(type_now x)"
    hmark
    ipc "$surface" toggle; ms 900
    p=$(probe "$cap_c" gf-click-c); pids+=("$p"); win_c=$(address_of "$p")
    ms 500
    say "$surface: window C opened while $surface is open (C $win_c), active: $(active)"
    keys -k Escape
    ms 2500
    mc=$(stat -c %s "$cap_c")
    say "$surface: closed with Escape, 2.5 s -> $(type_now x) C=$(cap_new "$cap_c" "$mc") active=$(active)"
    htrace
    read -r cx cy cw ch < <(geom "$win_c")
    mc=$(stat -c %s "$cap_c")
    click $((cx + cw / 2)) $((cy + ch / 2)); ms 400
    say "$surface: click C content -> $(type_now x) C=$(cap_new "$cap_c" "$mc") active=$(active)"
    mc=$(stat -c %s "$cap_c")
    click $((cx + cw / 2)) $((cy - 14)); ms 400
    say "$surface: click C titlebar -> $(type_now x) C=$(cap_new "$cap_c" "$mc") active=$(active)"
    kill "$p" 2>/dev/null
    ms 800
  done
  exit 0
fi

if [[ ${1:-explore} == activate ]]; then
  for surface in search apps notifications; do
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "$surface: A clicked -> $(type_now x)"
    hmark
    if [[ $surface == notifications ]]; then ipc notifications toggleCenter; else ipc "$surface" toggle; fi
    ms 900
    nestctl dispatch "hl.dsp.focus({ window = 'address:$win_b' })" >>"$log" 2>&1
    ms 400
    say "$surface: B activated while $surface is open, active: $(name_of "$(active)")"
    keys -k Escape
    ms 3000
    say "$surface: closed with Escape, 3 s -> $(type_now x)"
    htrace
    read -r x y <<<"$b_in"; click "$x" "$y"; ms 400
    say "$surface: click B content -> $(type_now x)"
    read -r x y <<<"$b_bar"; click "$x" "$y"; ms 400
    say "$surface: click B titlebar -> $(type_now x)"
    read -r x y <<<"$a_in"; click "$x" "$y"; ms 400
    say "$surface: click A content -> $(type_now x)"
  done
  exit 0
fi

if [[ ${1:-explore} == trace ]]; then
  click_a() { read -r x y <<<"$a_in"; click "$x" "$y"; ms 300; }
  click_a
  say "trace: A focused -> $(type_now x)"
  if [[ ${2:-ipc} == click ]]; then
    say "trace: open a menu with a click on the menu bar (150,12)"
    click 150 12
  else
    say "trace: open the system menu over IPC"
    ipc menubar open system "$out"
  fi
  poll_layers 8
  say "trace: Escape"
  keys -k Escape
  poll_layers 30
  say "trace: after 3 s idle -> $(type_now x)"
  read -r x y <<<"$b_in"
  say "trace: click B content"
  click "$x" "$y"
  ms 300
  say "trace: -> $(type_now x)"
  poll_layers 5
  say "trace: pointer moves 1 px"
  pointer abs $((x + 1)) "$y"
  poll_layers 10
  click "$x" "$y"
  ms 300
  say "trace: click B again -> $(type_now x)"
  exit 0
fi

step() { # <label> <commands...> ; then type and report
  local label=$1
  shift
  hmark
  "$@"
  say "$label -> $(type_now x)"
  htrace
}
click_a() { read -r x y <<<"$a_in"; click "$x" "$y"; ms 300; }
click_b() { read -r x y <<<"$b_in"; click "$x" "$y"; ms 300; }
bar_a() { read -r x y <<<"$a_bar"; click "$x" "$y"; ms 300; }
bar_b() { read -r x y <<<"$b_bar"; click "$x" "$y"; ms 300; }

step "0 click B content" click_b
step "1 click A content" click_a
step "2 click B content" click_b
step "3 click A titlebar" bar_a
step "4 click B titlebar" bar_b
search_open() { keys -M logo -k space -m logo; ms 700; }
esc() { keys -k Escape; ms 700; }
step "5a A focused, open Search" eval 'click_a; search_open'
step "5b Escape" esc
step "5c click B content" click_b
step "6a open Search" search_open
step "6b click A content (closes Search)" click_a
step "6c click A content again" click_a
apps_open() { keys -k F4; ms 900; }
step "7a open Apps" apps_open
step "7b Escape" esc
step "7c click B" click_b
nc_open() { keys -M logo -k n -m logo; ms 900; }
step "8a open Notification Center" nc_open
step "8b Escape" esc
step "8c click A" click_a
ov_open() { keys -M ctrl -k Up -m ctrl; ms 1200; }
step "9a open Overview" ov_open
step "9b Escape" esc
step "9c click B" click_b
desk() { click 60 $((mon_h / 2)); ms 300; }
step "10a click the desktop" desk
step "10b click A" click_a
menu() { click 150 12; ms 600; }
step "11a click the menu bar" menu
step "11b Escape" esc
step "11c click B" click_b
step "12a click the menu bar" menu
step "12b click A content (closes the menu)" click_a
step "12c click A content again" click_a
say "done (log $log)"
