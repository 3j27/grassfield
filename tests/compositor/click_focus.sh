#!/usr/bin/env bash
# Click-to-focus scenario (macOS model): a press anywhere on a window that does not hold the keyboard (its content or its
# Grassfield titlebar) makes it the key window, and the keys typed next reach it. Real-session bug 2026-10-20 (packages
# 0.4.0-3): "when a window does not have the focus, a simple click on it does not give it the focus back".
#
# Root cause (reproduced here, `unlock` cases): Hyprland 0.56.2 refocuses on a click only when the clicked window is not
# its focused window. After a session unlock with the pointer off the windows (desktop, menu bar) it keeps its last window
# focused while the keyboard is on no surface, so a click on that window did nothing (keys lost until another window was
# clicked first). grassfield-compositor 0.8.1-clickfocus gives the keyboard to Hyprland's focused window on such a press
# (docs/specs/compositor.md FR30 (d)). Two shell paths into "the keyboard is elsewhere" are checked too: a closed
# full-attention surface (Search, Apps, Notification Center, menus) kept its full-screen input region while it stayed mapped
# for the keyboard release, and the menu bar took the keyboard as a menu closed under a resting pointer.
#
# Usage: tests/compositor/click_focus.sh [check] [--headless]   every case below; exit 0 PASS, 1 FAIL, 2 environment error
#        tests/compositor/click_focus.sh unmap [--headless]     diagnostic: how long each closed surface stays mapped
#   --headless  WAYLAND-1 (the nested window, paced by the owner's session) is disabled for the run and enabled again at the
#               end, so every shell surface is paced by the nested Hyprland itself (as on real outputs); GF-REF only.
# NESTED only, run BARE (never chained or with a VAR= prefix): needs this tree's nested session (scripts/dev/nested-up.sh)
# with the real shell. Probe windows: foot capture windows (raw tty, every typed byte to a file) through
# scripts/dev/isolated.sh; other clients through isolated.sh on the nested Wayland socket and the nested private D-Bus bus
# (.dev/bus.address, never the owner's), with their keyboard truth from their own wl_keyboard enter/leave (WAYLAND_DEBUG);
# the XWayland client gets the nested Hyprland's own X display. Pointer through scripts/dev/pointer.sh, letters only through
# scripts/dev/keys.sh (never Return), shell surfaces through tests/visual/ipc.sh, the lock through the foreign locker fixture
# tests/security/foreign_locker (released over its IPC; nothing is typed while locked); scripts/nestctl only for reads,
# window moves and monitor rules of the nested instance. Only processes started here are stopped.
#
# Cases (check):
#   clients   foot, Qt (grassfield-settings), GTK4 (nautilus), Chromium and Electron (obsidian) on Wayland, Chromium on
#             XWayland: with foot A holding the keyboard, a click on the client's content, then on its titlebar, gives it
#             the keyboard (client's wl_keyboard enter, Hyprland's active window; Chromium: the typed letter reaches its page)
#   closed    Search, Apps, Notification Center, Overview, a menu (Escape) and a menu closed by a click outside (that click is
#             the menu's, as on macOS): once the keys are back in A, a click on window B gives B the keyboard (a second click
#             when the first fell between the keyboard release and the empty input mask) and no app is launched; a click on
#             another window while the Overview is still "releasing" (dev hook holdNextRelease) reaches it
#   menubar   a menu opened from the bar and closed with Escape while the pointer rests on the bar: the keys reach the window
#             that was active (not the bar), and a click on another window works; a click on the bare bar keeps the keys
#   layer     an on-demand layer surface of another client (tests/compositor/click-focus-fixture) took the keyboard while
#             Hyprland still counts A focused: a click on A's content (and on its titlebar) gives A the keyboard
#   unlock    lock and unlock with the pointer on the bare desktop, on the menu bar, on window A: the keys reach A with no
#             click (plugin 0.8.2), and a click on A's content (and on its titlebar) gives A the keyboard
#   health    Hyprland alive, no grassfield exception in its log
# Without grassfield-compositor (C2: scripts/nestctl plugin unload, or nested-up.sh --no-plugin) the titlebar cases are
# skipped (no titlebars) and the unlock clicks are reported only: Hyprland 0.56.2 alone does nothing there (known limit).
# Timing: a closed surface's keyboard release and empty input mask land when the shell's GUI thread commits them; in a
# loaded nested session that took seconds, and in C2 the shell's focus-return retry, delayed the same way, can take the
# keyboard back from a window clicked in the meantime (known C2 limit).
# Logs: .dev/click-focus/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=GF-REF
mode=check
headless_wanted=0
sections=()
for arg in "$@"; do
  case $arg in
    check | unmap) mode=$arg ;;
    clients | closed | menubar | layer | unlock) sections+=("$arg") ;;
    --headless) headless_wanted=1 ;;
    *) echo "usage: click_focus.sh [check [clients|closed|menubar|layer|unlock]...|unmap] [--headless]" >&2; exit 2 ;;
  esac
done
((${#sections[@]})) || sections=(clients closed menubar layer unlock)
wanted() { [[ " ${sections[*]} " == *" $1 "* ]]; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID

for tool in jq foot socat qs; do
  command -v "$tool" >/dev/null || { echo "click_focus: $tool not installed" >&2; exit 2; }
done
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
case $bus in unix:path=/tmp/dbus-*) ;; *) echo "click_focus: no nested private bus (.dev/bus.address); start with scripts/dev/nested-up.sh --private-bus" >&2; exit 2 ;; esac

run=$dev/click-focus/run-$(date +%Y%m%d-%H%M%S)-$mode
mkdir -p "$run"
log=$run/run.log
hyprlog=${XDG_RUNTIME_DIR:?}/hypr/$sig/hyprland.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
ipc() { timeout 5 "$root/tests/visual/ipc.sh" "$@" >>"$log" 2>&1; }
ipcq() { timeout 5 "$root/tests/visual/ipc.sh" "$@" 2>>"$log"; } # its answer on stdout
wait_for() { # <ms> <command...>: true once the command succeeds (polled every 100 ms), false after <ms>
  local limit=$1 t0
  shift
  t0=$(date +%s%3N)
  until "$@"; do
    (($(date +%s%3N) - t0 > limit)) && return 1
    ms 100
  done
}
ms() { sleep "$(awk -v m="$1" 'BEGIN { printf "%.3f", m / 1000 }')"; }
click() { pointer abs "$1" "$2" sleep 150 click; }

pids=()
headless=0
log0=$(grep -ac "" "$hyprlog" 2>/dev/null || echo 0)
# Lua monitor rule through the nested instance (hl.dispatch's "expected a dispatcher" error is harmless: the rule applied).
monrule() { nestctl dispatch "hl.monitor($1)" >/dev/null 2>&1 || true; sleep 0.8; }
wayland1_enabled() { nestctl monitors -j 2>/dev/null | jq -e 'any(.[]; .name == "WAYLAND-1")' >/dev/null 2>&1; }
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
foreign_ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }
locker_pid=""
cleanup() {
  if [[ -n $locker_pid ]] && kill -0 "$locker_pid" 2>/dev/null; then
    foreign_ipc unlock >/dev/null # never leave the nested session locked
    sleep 0.5
    kill "$locker_pid" 2>/dev/null
  fi
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  if ((headless)); then
    for _ in 1 2 3; do
      monrule '{ output = "WAYLAND-1", disabled = false, mode = "1440x900", position = "auto", scale = 1 }'
      wayland1_enabled && break
    done
    monrule '{ output = "GF-REF", mode = "1920x1080@60", position = "auto-right", scale = 1 }'
    wayland1_enabled || echo "WARNING: WAYLAND-1 is still disabled in the nested session" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM
if ((headless_wanted)); then
  headless=1
  monrule '{ output = "WAYLAND-1", disabled = true }'
  monrule '{ output = "GF-REF", mode = "1920x1080@60", position = "0x0", scale = 1 }'
  sleep 2
fi

read -r mon_x mon_y mon_w mon_h < <(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "click_focus: output $out not found" >&2; exit 2; }
# Windows left by someone else would cover the probes (they are never closed here).
others=$(nestctl -j clients | jq -r '[.[] | select(.mapped) | "\(.address) \(.class)"] | join(", ")')
if [[ -n $others ]]; then
  echo "click_focus: the nested session already has windows ($others); close them first" >&2
  exit 2
fi

# ---- windows ----
probe() { # <capture> <title> -> pid; every typed byte goes to <capture>
  : >"$1"
  WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus setsid "$root/scripts/dev/isolated.sh" --name click-focus foot --title "$2" -w 640x400 \
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
place() { # <address> <x> <y> (output-local)
  nestctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$1' })" >>"$log" 2>&1
}
active() { nestctl -j activewindow 2>/dev/null | jq -r '.address // "none"'; }
window_count() { nestctl -j clients | jq 'length'; }
name_of() {
  case $1 in
    "$win_a") echo A ;; "$win_b") echo B ;; none | "") echo none ;; *) echo "other($1)" ;;
  esac
}

cap_a=$run/a.cap cap_b=$run/b.cap
mark_a=0 mark_b=0
mark() { mark_a=$(stat -c %s "$cap_a"); mark_b=$(stat -c %s "$cap_b"); }
cap_new() { tail -c +"$(($2 + 1))" "$1" | tr -d '\n'; }
# Types <letter> and reports where it went: "A=<..> B=<..> active=<A|B|none|other>".
type_now() {
  mark
  keys "$1"
  ms 400
  printf 'A=%s B=%s active=%s' "$(cap_new "$cap_a" "$mark_a")" "$(cap_new "$cap_b" "$mark_b")" "$(name_of "$(active)")"
}
# Escape, then letters until one lands in a window: a busy shell may not handle the first key of a surface that just
# opened, so a lost Escape is sent again every 6 probes (~2.4 s), at most 3 in all. Sets $r (the last probe), $probes (how
# many were typed) and $landed (ms since the first Escape; "" when no letter landed). True when A got the letter.
escape_until_a() {
  local t0 esc=1
  t0=$(date +%s%3N)
  landed=""
  keys -k Escape
  for ((probes = 1; probes <= 25; probes++)); do
    r=$(type_now x)
    if [[ $r == A=*x* || $r == *B=*x* ]]; then
      landed=$(($(date +%s%3N) - t0))
      [[ $r == A=*x* ]]
      return
    fi
    if ((probes % 6 == 0 && esc < 3)); then
      keys -k Escape
      esc=$((esc + 1))
    fi
  done
  return 1
}

fail=0 passed=0 total=0
check() { # <label> <0|1> [detail]
  total=$((total + 1))
  if [[ $2 == 0 ]]; then
    passed=$((passed + 1))
    say "  PASS $1${3:+ ($3)}"
  else
    say "  FAIL $1${3:+ ($3)}"
    fail=1
  fi
}

say "click_focus $mode: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag), commit $(nestctl -j version | jq -r .commit | cut -c1-8)), $out ${mon_w}x${mon_h}, headless $headless"
say "plugin: $(nestctl plugin list 2>/dev/null | grep -m1 -i 'version' | tr -s ' ' || echo none); features $(nestctl -j grassfield 2>/dev/null | jq -c .features 2>/dev/null || echo none)"
# Without grassfield-compositor (C2) there are no titlebars, and the click on Hyprland's focused window after an unlock is
# Hyprland's own behaviour (it does nothing): those cases are reported, not checked.
plugin=0
nestctl -j grassfield 2>/dev/null | jq -e '.features | index("desktop-focus")' >/dev/null 2>&1 && plugin=1
((plugin)) || say "C2: grassfield-compositor not loaded (or without desktop-focus): titlebar cases skipped, unlock clicks reported only"
paths=(content)
((plugin)) && paths+=(titlebar)

# Anchor devices for the whole run (as tests/compositor/minimize.sh): a virtual pointer and a virtual keyboard that only wait,
# so the seat keeps both capabilities while pointer.sh and keys.sh add and remove their own devices. Without any keyboard
# device Hyprland refuses every keyboard focus ("setKeyboardFocus without a valid keyboard") and every key check fails.
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 &
pids+=($!)
"$root/scripts/dev/keys.sh" -s 3600000 >>"$log" 2>&1 &
pids+=($!)
# Hyprland's log as it is written (read-only hyprctl request; the log file itself is written late).
follow=$run/hyprland-follow.log
timeout 3600 stdbuf -oL "$root/scripts/nestctl" rollinglog -f >"$follow" 2>&1 &
pids+=($!)
# Read as text: hyprctl's JSON for a virtual pointer can hold a non-numeric value that jq refuses.
keyboard_names() { nestctl -j devices 2>/dev/null | sed -n '/"keyboards"/,/^\]/p' | sed -n 's/.*"name": "\(.*\)",/\1/p' | tr '\n' ' '; }
has_keyboard() { [[ -n $(keyboard_names) ]]; }
if ! wait_for 5000 has_keyboard; then
  say "setup error: the nested session has no keyboard device (keys could reach no window)"
  exit 2
fi
say "keyboards: $(keyboard_names)"

pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 50 # windows open on the output under the pointer
p=$(probe "$cap_a" gf-click-a); pids+=("$p"); win_a=$(address_of "$p")
p=$(probe "$cap_b" gf-click-b); pids+=("$p"); win_b=$(address_of "$p")
[[ -n $win_a && -n $win_b ]] || { say "setup error: probe windows did not map"; exit 2; }
place "$win_a" 60 160
place "$win_b" 1000 160
ms 800
read -r ax ay aw ah < <(geom "$win_a")
read -r bx by bw bh < <(geom "$win_b")
say "A $win_a ${aw}x${ah}+$ax+$ay   B $win_b ${bw}x${bh}+$bx+$by"
a_in="$((ax + aw / 2)) $((ay + ah / 2))"
b_in="$((bx + bw / 2)) $((by + bh / 2))"
a_bar="$((ax + aw / 2)) $((ay - GF_TB_MID))"
b_bar="$((bx + bw / 2)) $((by - GF_TB_MID))"
desk="$((mon_w / 2)) $((mon_h - 260))" # bare desktop between the windows and the Dock
click_a() { local x y; read -r x y <<<"$a_in"; click "$x" "$y"; ms "${1:-400}"; }
click_b() { local x y; read -r x y <<<"$b_in"; click "$x" "$y"; ms "${1:-400}"; }
focus_a() { # A holds the keyboard (checked)
  click_a
  local r
  r=$(type_now x)
  [[ $r == "A=x B= active=A" ]] || say "  note: A did not take the keyboard at the start of a case ($r)"
}

# ---- diagnostic: how long a closed surface stays mapped ----
layer_mapped() { nestctl -j layers | jq -e --arg o "$out" --arg n "$1" '[.[$o].levels[][] | .namespace] | index($n)' >/dev/null; }
gone_after() { # <namespace> -> ms until it is no longer mapped (max 8000)
  local t0 now
  t0=$(date +%s%3N)
  while layer_mapped "$1"; do
    now=$(date +%s%3N)
    ((now - t0 > 8000)) && { echo "never"; return; }
  done
  echo $(($(date +%s%3N) - t0))
}
if [[ $mode == unmap ]]; then
  # A click on B 300 ms after the close, with whether the closed surface was still mapped then.
  for ns in search:grassfield-search apps:grassfield-apps menu:grassfield-overlay; do
    name=${ns%%:*} layer=${ns#*:}
    for round in 1 2 3; do
      focus_a
      case $name in search) ipc search toggle ;; apps) ipc apps toggle ;; menu) ipc menubar open system "$out" ;; esac
      ms 1000
      n0=$(window_count)
      keys -k Escape
      ms 300
      layer_mapped "$layer" && still=mapped || still=gone
      click_b
      r=$(type_now x)
      say "click-through $name $round: $layer $still at the click -> $r, windows $n0 -> $(window_count)"
    done
  done
  for round in 1 2 3; do
    focus_a
    ipc menubar open system "$out"; ms 600; keys -k Escape
    say "unmap $round: menu (Escape): gone after $(gone_after grassfield-overlay) ms"
    ipc search toggle; ms 800; keys -k Escape
    say "unmap $round: Search (Escape): gone after $(gone_after grassfield-search) ms"
    ipc apps toggle; ms 800; keys -k Escape
    say "unmap $round: Apps (Escape): gone after $(gone_after grassfield-apps) ms"
    ipc notifications toggleCenter; ms 800; keys -k Escape
    say "unmap $round: Notification Center (Escape): gone after $(gone_after grassfield-notification-center) ms"
  done
  exit 0
fi

# ---- clients ----
# start_client <name> -> pid; its wl_keyboard enter/leave lines go to $run/<name>.kbd (Wayland clients only).
xdisplay=""
start_client() {
  local name=$1 kbd=$run/$1.kbd page
  : >"$kbd"
  # An app window (no address bar) whose title echoes every key the page receives.
  page="--app=data:text/html,<title>gf-chromium</title><body style='background:%23336' onkeydown='window.n=(window.n||0)+1;document.title=\"gf-chromium-\"+window.n+\"-\"+event.key'>"
  local -a cmd envs=(WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus")
  case $name in
    chromium) cmd=(/usr/lib/chromium/chromium --ozone-platform=wayland --user-data-dir="$run/chromium-profile" --no-first-run
      --no-default-browser-check --password-store=basic --disable-sync --window-size=900,600 "$page") ;;
    # isolated.sh drops DISPLAY: the nested X display is set inside it, and no Wayland socket at all (an X11 client only).
    xwayland) cmd=(env -u WAYLAND_DISPLAY DISPLAY="$xdisplay" /usr/lib/chromium/chromium --ozone-platform=x11
      --user-data-dir="$run/xwayland-profile" --no-first-run --no-default-browser-check --password-store=basic --disable-sync
      --window-size=900,600 "$page") ;;
    electron) cmd=(obsidian --ozone-platform=wayland --enable-features=UseOzonePlatform --user-data-dir="$run/obsidian-profile") ;;
    gtk4) cmd=(nautilus --new-window "$run") ;;
    qt) cmd=(grassfield-settings) ;;
  esac
  if [[ $name == xwayland ]]; then
    env -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name "click-focus-$name" "${cmd[@]}" \
      >"$run/xwayland.out" 2>&1 </dev/null &
  else
    # The client's stderr carries the WAYLAND_DEBUG trace; only keyboard enter/leave lines are kept.
    env "${envs[@]}" WAYLAND_DEBUG=client setsid "$root/scripts/dev/isolated.sh" --name "click-focus-$name" "${cmd[@]}" \
      2> >(grep --line-buffered -E 'wl_keyboard#[0-9]+\.(enter|leave)\(' >"$kbd") >/dev/null </dev/null &
  fi
  echo $!
}
kbd_of() { # yes when the client's last wl_keyboard event was an enter
  local last
  last=$(grep -E '\.(enter|leave)\(' "$run/$1.kbd" 2>/dev/null | tail -n 1)
  [[ $last == *".enter("* ]] && echo yes || echo no
}
title_of() { nestctl -j clients | jq -r --arg a "$1" '.[] | select(.address == $a) | .title'; }

client_case() { # <name>
  local name=$1 p before win_c="" cx cy cw ch path x y kb act title extra st
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 50
  before=$(nestctl -j clients | jq -r '[.[].address] | join(" ")')
  p=$(start_client "$name"); pids+=("$p")
  for _ in $(seq 1 120); do
    win_c=$(nestctl -j clients | jq -r --arg b "$before" \
      '[.[] | select(.mapped and (.address as $x | ($b | split(" ") | index($x)) == null))] | last | .address // ""')
    [[ -n $win_c ]] && break
    ms 250
  done
  if [[ -z $win_c ]]; then
    check "$name: a window maps" 1 "no window after 30 s"
    return
  fi
  ms 2500
  place "$win_c" 760 90
  ms 800
  read -r cx cy cw ch < <(geom "$win_c")
  say "$name: window $win_c ${cw}x${ch}+$cx+$cy class $(nestctl -j clients | jq -r --arg a "$win_c" '.[] | select(.address == $a) | "\(.class) xwayland \(.xwayland)"')"
  for path in "${paths[@]}"; do
    focus_a
    # Content: near the left edge, half-way down (clear of the centre buttons of a welcome screen such as Obsidian's).
    if [[ $path == content ]]; then x=$((cx + 30)) y=$((cy + ch / 2)); else x=$((cx + cw / 2)) y=$((cy - GF_TB_MID)); fi
    click "$x" "$y"
    ms 700
    act=$(active)
    extra=""
    case $name in
      xwayland | chromium)
        # The page counts its key events in its title. The virtual keyboard's keymap does not reach XWayland clients as
        # typed (wtype's x arrives as another keysym): any new key event there is the evidence.
        before=$(title_of "$win_c")
        mark; keys x; ms 700
        title=$(title_of "$win_c")
        extra="title '$before' -> '$title', A got '$(cap_new "$cap_a" "$mark_a")'"
        st=1
        if [[ $act == "$win_c" && $title != "$before" && $title == gf-chromium-* && -z $(cap_new "$cap_a" "$mark_a") ]]; then
          [[ $name == xwayland || $title == *-x ]] && st=0
        fi
        [[ $name == chromium ]] && extra="$extra, wl_keyboard enter: $(kbd_of "$name")"
        check "$name: a click on its $path gives it the keyboard" "$st" "active $(name_of "$act"), $extra"
        ;;
      *)
        kb=$(kbd_of "$name")
        [[ $act == "$win_c" && $kb == yes ]]
        check "$name: a click on its $path gives it the keyboard" $? "active $(name_of "$act"), wl_keyboard enter: $kb"
        ;;
    esac
  done
  kill "$p" 2>/dev/null
  nestctl dispatch "hl.dsp.window.close({ window = 'address:$win_c' })" >>"$log" 2>&1
  ms 1500
}

if wanted clients; then
say "== clients: a click on the content and on the titlebar of a window without the keyboard"
focus_a
click_b
r=$(type_now x)
[[ $r == "A= B=x active=B" ]]
check "foot: a click on its content gives it the keyboard" $? "$r"
if ((plugin)); then
  focus_a
  read -r x y <<<"$b_bar"; click "$x" "$y"; ms 400
  r=$(type_now x)
  [[ $r == "A= B=x active=B" ]]
  check "foot: a click on its titlebar gives it the keyboard" $? "$r"
fi
# The nested Hyprland's own X display (its children inherit it); never the owner's.
nestctl dispatch "hl.dsp.exec_cmd('printf %s \"\$DISPLAY\" > $run/xdisplay')" >>"$log" 2>&1
ms 800
xdisplay=$(cat "$run/xdisplay" 2>/dev/null || true)
for name in qt gtk4 chromium electron xwayland; do
  case $name in
    chromium | xwayland) [[ -x /usr/lib/chromium/chromium ]] || { say "$name: SKIP (chromium not installed)"; continue; } ;;
    electron) command -v obsidian >/dev/null || { say "$name: SKIP (no Electron app: obsidian not installed)"; continue; } ;;
    gtk4) command -v nautilus >/dev/null || { say "$name: SKIP (nautilus not installed)"; continue; } ;;
    qt) command -v grassfield-settings >/dev/null || { say "$name: SKIP (grassfield-settings not installed)"; continue; } ;;
  esac
  if [[ $name == xwayland && ! $xdisplay =~ ^:[0-9]+$ ]]; then
    say "xwayland: SKIP (the nested Hyprland has no X display: '${xdisplay}')"
    continue
  fi
  # Never the caller's X server (the owner's session).
  if [[ $name == xwayland && $xdisplay == "${DISPLAY:-}" ]]; then
    say "xwayland: SKIP (the nested X display $xdisplay is the caller's own)"
    continue
  fi
  client_case "$name"
done
fi

# ---- right after a full-attention surface closed ----
# The surface stays mapped a moment after it releases the keyboard (shell/platform/KeyboardRelease.qml, longer whenever the
# shell's GUI thread is busy): it must not catch the click meant for the window under it.
surface_layer() { # <name> -> its layer namespace
  case $1 in
    search) echo grassfield-search ;;
    apps) echo grassfield-apps ;;
    notifications) echo grassfield-notification-center ;;
    overview) echo grassfield-overview-backdrop ;;
    menu) echo grassfield-overlay ;;
  esac
}
overview_stage() { ipcq overview status | jq -r '"\(.stage) \(.chromeHeld)"' 2>/dev/null; }
overview_is() { [[ $(overview_stage) == "$1" ]]; }
open_surface() { # <name>: opened, mapped and (for the Overview) holding the keyboard
  case $1 in
    search) ipc search toggle ;;
    apps) ipc apps toggle ;;
    notifications) ipc notifications toggleCenter ;;
    overview) ipc overview toggle ;;
    menu) ipc menubar open system "$out" ;;
  esac
  if [[ $1 == overview ]]; then # its chrome is mapped all the time (and its backdrop only in v2): the stage tells
    wait_for 5000 overview_is "open true" || say "  note: the Overview's chrome did not take the keyboard within 5 s ($(overview_stage))"
  else
    wait_for 5000 layer_mapped "$(surface_layer "$1")" || say "  note: $1 did not map within 5 s"
  fi
}
if wanted closed; then
say "== a click on another window right after a surface closed"
for entry in search:grassfield-search apps:grassfield-apps notifications:grassfield-notification-center \
  overview:grassfield-overview-backdrop menu:grassfield-overlay; do
  surface=${entry%%:*} layer=${entry#*:}
  focus_a
  open_surface "$surface"
  n0=$(window_count)
  # The close has landed once the keys reach A again (the surface released the keyboard and it came back to A); the
  # surface itself may stay mapped longer (the hold, the fade, a busy GUI thread): the click must go through it.
  escape_until_a
  if [[ $surface == overview ]]; then
    still="stage '$(overview_stage)'"
  else
    layer_mapped "$layer" && still=mapped || still=unmapped
  fi
  click_b
  r=$(type_now x)
  # The keyboard release and the empty input mask are separate commits: a click between them (one frame, seconds when the
  # shell is busy) is the closing surface's. A second click must then work.
  first=ok
  if [[ $r != "A= B=x active=B" ]]; then
    first="swallowed ($r)"
    click_b
    r=$(type_now x)
  fi
  [[ $surface == apps ]] && ms 2500 # an app launched by a tile would map by now
  n1=$(window_count)
  [[ $r == "A= B=x active=B" && $n1 == "$n0" ]]
  check "$surface closed with Escape: a click on B gives B the keyboard, nothing else happens" $? \
    "$r; keys back in A after ${landed:-never} ms; $layer $still at the click; first click $first; windows $n0 -> $n1"
done
# A click outside an open menu closes it and is the menu's (macOS); the next click on that window gives it the keyboard.
focus_a
open_surface menu
click_b 0
landed=""
t0=$(date +%s%3N)
for ((p = 1; p <= 25; p++)); do
  r=$(type_now x)
  [[ $r == A=*x* || $r == *B=*x* ]] && { landed=$(($(date +%s%3N) - t0)); break; }
  # A menu that just opened may not have its input region yet when the shell is busy: the click went past it and the menu
  # still holds the keys. Clicked again, as a user would.
  ((p % 6 == 0)) && click_b 0
done
# Its input mask can land after its keyboard release when the GUI thread is busy (a click in between is the closing
# surface's): the next click is made once the menu's surface is gone.
gone=$(gone_after grassfield-overlay)
click_b
r=$(type_now x)
[[ -n $landed && $r == "A= B=x active=B" ]]
check "menu closed by a click on B: the next click on B gives B the keyboard" $? "$r; close landed after ${landed:-never} ms; grassfield-overlay unmapped $gone ms later"
# The Overview while it releases the keyboard (R13 finding M1 on 0f3adf7): its stage stays "releasing" until every chrome
# committed None, and the chrome kept its full-screen input all that time. Held 3 s by the dev hook, so that the click
# lands in that stage once the chromes no longer hold the keyboard.
focus_a
open_surface overview
held=$(ipcq overview holdNextRelease 8000)
keys -k Escape
# A lost Escape (a busy shell) is sent again while the Overview still reads as open.
for _ in 1 2 3; do
  wait_for 2500 overview_is "releasing false" && break
  [[ $(overview_stage) == open* ]] && keys -k Escape
done
# Reported: whether the keys are back in A before the click (Hyprland's refocus or the plugin's request done).
back=""
for ((i = 1; i <= 4; i++)); do
  r=$(type_now x)
  [[ $r == A=*x* ]] && { back=$i; break; }
done
at_click=$(overview_stage)
click_b
after_click=$(overview_stage)
r=$(type_now x)
# With the plugin (v2) a press while its focus request waits is recorded and the plugin focuses the window under it, so B
# gets the keyboard even when the chrome swallowed the click; in thumbnail mode and without the plugin (C2) only the
# chrome's input region decides: there this case fails on the pre-fix mask (input while the stage is not "closed").
[[ $held == held && $at_click == "releasing false" && $after_click == releasing* && $r == "A= B=x active=B" ]]
check "overview releasing (chromes released, stage held): a click on B gives B the keyboard" $? \
  "$r; hold $held; keys back in A after ${back:-no} probe(s); stage at the click '$at_click', after it '$after_click'"
wait_for 6000 overview_is "closed false" || say "  note: the Overview did not finish closing ($(overview_stage))"
fi

# ---- the menu bar never keeps the keyboard ----
if wanted menubar; then
say "== a menu opened from the bar and closed with Escape while the pointer rests on the bar"
for round in 1 2 3; do
  focus_a
  click 150 12 # a title of the bar (the app's menus): opens its menu, the pointer stays on the bar
  wait_for 5000 layer_mapped grassfield-overlay || say "  note: the menu did not open within 5 s"
  # Letters are typed until they land in a window (lost ones went to the menu, the bar or nowhere); the first that lands
  # must be A's.
  escape_until_a
  check "round $round: after Escape the keys reach A, the window active when the menu opened" $? "$r after $((probes - 1)) lost letter(s)"
  gone_after grassfield-overlay >/dev/null # a click while it closes is the `closed` section's case
  click_b
  r=$(type_now x)
  [[ $r == "A= B=x active=B" ]]
  check "round $round: a click on B then gives B the keyboard" $? "$r"
done
# A click on an empty part of the bar (keyboard None) leaves the keys with the window (macOS: the app stays key).
focus_a
click $((mon_w / 2)) 12
ms 500
r=$(type_now x)
[[ $r == "A=x B= active=A" ]]
check "a click on an empty part of the menu bar leaves the keyboard on A" $? "$r"
fi

# ---- a layer surface of another client took the keyboard ----
# tests/compositor/click-focus-fixture: an on_demand layer surface (Top layer) that takes the keyboard when clicked, while
# Hyprland keeps A as its focused window. A click on A must give A the keyboard (FR30 (d); Hyprland 0.56.2 alone does
# nothing: A is already its focused window).
if wanted layer; then
say "== a layer surface of another client (on_demand) took the keyboard"
fixlog=$run/fixture.log
: >"$fixlog"
WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig GF_CF_OUTPUT=$out DBUS_SESSION_BUS_ADDRESS=$bus \
  setsid "$root/scripts/dev/isolated.sh" --name click-focus-fixture qs -p "$root/tests/compositor/click-focus-fixture" --no-color \
  >>"$fixlog" 2>&1 </dev/null &
fixture_pid=$!
pids+=("$fixture_pid")
if ! wait_for 8000 layer_mapped click-focus-fixture; then
  check "layer fixture: mapped" 1 "see $fixlog"
else
  fix_x=$((mon_w - 40 - 110)) fix_y=$((300 + 60))
  for path in "${paths[@]}"; do
    focus_a
    click "$fix_x" "$fix_y"
    ms 300
    k0=$(grep -ac "\[cf-fixture\] key" "$fixlog")
    r0=$(type_now x)
    k1=$(grep -ac "\[cf-fixture\] key" "$fixlog")
    say "  fixture clicked: keys to the fixture $((k1 - k0)), $r0"
    if [[ $path == content ]]; then read -r x y <<<"$a_in"; else read -r x y <<<"$a_bar"; fi
    click "$x" "$y"
    ms 400
    r=$(type_now x)
    if ((plugin)); then
      [[ $((k1 - k0)) -ge 1 && $r0 == "A= B= active=A" && $r == "A=x B= active=A" ]]
      check "a layer surface took the keyboard, Hyprland still counts A focused: a click on A's $path gives A the keyboard" $? \
        "fixture got $((k1 - k0)) key(s), then $r0; after the click $r"
    else
      say "  C2 (known limit, Hyprland 0.56.2): fixture got $((k1 - k0)) key(s) ($r0); a click on A's $path: $r"
    fi
  done
fi
kill "$fixture_pid" 2>/dev/null
layer_gone() { ! layer_mapped "$1"; }
wait_for 3000 layer_gone click-focus-fixture || say "  note: the fixture is still mapped"
fi

# ---- after a session unlock ----
lock_cycle() { # the foreign locker takes the session lock, then releases it over IPC (nothing is typed while locked)
  local locked="" i
  WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig GRASSFIELD_FOREIGN_LOCKER=1 \
    setsid "$root/scripts/dev/isolated.sh" --name click-focus-locker qs -p "$foreign" --no-color >>"$run/locker.log" 2>&1 </dev/null &
  locker_pid=$!
  for i in $(seq 1 60); do
    locked=$(foreign_ipc status)
    [[ $locked == "locked secure" ]] && break
    ms 100
  done
  ms 600
  foreign_ipc unlock >/dev/null
  for i in $(seq 1 30); do kill -0 "$locker_pid" 2>/dev/null || break; ms 100; done
  kill -0 "$locker_pid" 2>/dev/null && kill "$locker_pid" 2>/dev/null
  locker_pid=""
  [[ $locked == "locked secure" ]]
}
if wanted unlock; then
say "== after a session unlock (foreign locker fixture)"
for where in desktop bar window; do
  for path in "${paths[@]}"; do
    focus_a
    case $where in
      desktop) read -r x y <<<"$desk"; pointer abs "$x" "$y" ;;
      bar) pointer abs 700 12 ;;
      window) read -r x y <<<"$a_in"; pointer abs $((x + 30)) "$y" ;;
    esac
    if ! lock_cycle; then
      check "unlock with the pointer on the $where: the session was locked" 1 "foreign locker did not lock"
      continue
    fi
    # macOS model: the window active before the lock has the keys again with no click (plugin 0.8.2: refocus after the
    # unlock; Hyprland 0.56.2 alone leaves the keyboard on no surface when the pointer is off the windows). Letters are
    # typed until one lands in a window (max 25 x 400 ms); none lost is not required (the unlock is asynchronous).
    lost=0
    for _ in $(seq 1 25); do
      r=$(type_now x)
      [[ $r == A=x* || $r == *B=x* ]] && break
      lost=$((lost + 1))
    done
    if ((plugin)); then
      [[ $r == "A=x B= active=A" ]]
      check "unlock with the pointer on the $where: the keys reach A with no click" $? "$r after $lost lost letter(s)"
    else
      say "  C2: unlock with the pointer on the $where, keys with no click: $r after $lost lost letter(s)"
    fi
    if [[ $path == content ]]; then read -r x y <<<"$a_in"; else read -r x y <<<"$a_bar"; fi
    click "$x" "$y"
    ms 400
    r=$(type_now x)
    if ((plugin)); then
      [[ $r == "A=x B= active=A" ]]
      check "unlock with the pointer on the $where: a click on A's $path gives A the keyboard" $? "$r"
    else
      say "  C2 (known limit, Hyprland 0.56.2): unlock with the pointer on the $where, a click on A's $path: $r"
    fi
  done
done
fi

# ---- health ----
kill -0 "$hypr_pid" 2>/dev/null
check "Hyprland alive" $?
exc=$(tail -n +"$((log0 + 1))" "$hyprlog" 2>/dev/null | grep -a "\[grassfield\]" | grep -aic "exception" || true)
((exc == 0))
check "no grassfield exception in the nested log" $? "$exc line(s)"
nokbd=$(grep -ac "without a valid keyboard" "$follow" || true)
((nokbd == 0))
check "the seat always had a keyboard (no 'setKeyboardFocus without a valid keyboard')" $? "$nokbd line(s)"

say "click_focus: $passed/$total PASS (log $log)"
((fail)) && exit 1
exit 0
