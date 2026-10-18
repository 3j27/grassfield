#!/usr/bin/env bash
# Desktop focus policy scenario (feature "desktop-focus", ADR-0012 amendment, docs/specs/desktop.md "Compositor focus
# policy"): grassfield-compositor makes the desktop surface click-to-focus like macOS.
#
# Usage: tests/compositor/desktop_focus.sh [check]     the policy with the plugin loaded (default)
#        tests/compositor/desktop_focus.sh baseline    the same presses with the plugin unloaded: shows the Hyprland
#                                                      0.56.2 behaviour the policy fixes (cases 1, 2 and 4 expected to
#                                                      fail there); the plugin is loaded again at the end
#        tests/compositor/desktop_focus.sh race        case 7 only, against whatever plugin build is loaded (no unload):
#                                                      shows the late-commit race on a build without the fix
#        tests/compositor/desktop_focus.sh stale       case 8 only, against whatever plugin build is loaded (no unload)
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded and two outputs (WAYLAND-1 and the
# headless GF-REF). The shell's desktop is stood in for by tests/compositor/desktop-focus-fixture (desktop surface
# namespace grassfield-desktop-icons on every output, behaving as the shell does with the capability: OnDemand on a
# left press, None when it loses the keyboard, no kicker, no pointer-leave drop; a Dock and a menu bar with keyboard
# None; a right-press menu with a popup grab). Probe foot windows through scripts/dev/isolated.sh write every typed byte
# to a capture file; pointer and keys through scripts/dev/pointer.sh and scripts/dev/keys.sh; plugin unload / load
# through scripts/nestctl.
#
# Cases (check):
#   1 desktop focused, click the foot that is Hyprland's last active window: the foot gets the keys
#   2 click the desktop and type at once, no pointer motion after the press: the desktop gets the keys (5 rounds)
#   3 desktop focused, hover the Dock, hover the menu bar, press on the Dock and on the menu bar: the desktop keeps the keys
#   4 desktop focused on GF-REF, click the last active foot on WAYLAND-1: that foot gets the keys
#   6 the desktop's popup menu keeps its grab: keys go to the menu, Esc gives them back to the desktop; an outside click
#     on a foot is swallowed (the grab's), and the next click on that foot gives it the keys
#   8 menu open, the pointer moves onto the last active foot, Esc, then a click without any pointer motion (Hyprland's
#     pointer focus is still the closed popup's surface): the foot gets the keys (shell integration finding, main 9e76bd7)
#   7 slow desktop commit (the fixture switches to OnDemand 700 ms after the press): a focus dispatch (what a key binding
#     runs) or a new window within that time keeps the keyboard and the late commit does not take it back (plugin log: the pending
#     grant was cancelled); without interference the late commit still gives the desktop the keys (R13 review of 5706cbd)
#   5 unload the plugin while the desktop holds the keyboard: Hyprland alive, capabilities withdrawn (empty list), keys
#     still delivered (to the desktop), a click on another foot works; loaded again: "desktop-focus" back, policy works
#   health: Hyprland alive, no core dump of its PID, no grassfield exception in the nested log
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
mode=${1:-check}
case $mode in
  check | baseline | race | stale) ;;
  *) echo "usage: desktop_focus.sh [check|baseline|race|stale]" >&2; exit 2 ;;
esac

out_a=GF-REF
out_b=WAYLAND-1
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh): a stale record
# may name another worktree's session.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
plugin=$root/compositor/build/grassfield-compositor.so
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "desktop_focus: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "desktop_focus: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat jq foot qs; do
  command -v "$tool" >/dev/null || { echo "desktop_focus: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
has_feature() { nestctl -j grassfield 2>/dev/null | jq -e '.features | index("desktop-focus")' >/dev/null; }
has_feature || { echo "desktop_focus: the loaded plugin does not advertise \"desktop-focus\"" >&2; exit 2; }

run=$dev/desktop-focus/run-$(date +%Y%m%d-%H%M%S)-$mode
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
fixlog=$run/fixture.log
start_human=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }

pids=()
socat_pid=""
fixture_pid=""
plugin_unloaded=0
cleanup() {
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  if ((plugin_unloaded)); then
    nestctl plugin load "$plugin" >/dev/null 2>&1 # never leave the nested session without the plugin
  fi
}
trap cleanup EXIT

socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null >"$events" &
socat_pid=$!

# Output geometry (layout coordinates).
mon() { nestctl -j monitors | jq -r --arg o "$1" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"'; }
read -r ax ay aw ah < <(mon "$out_a")
read -r bx by bw bh < <(mon "$out_b")
[[ -n ${aw:-} && -n ${bw:-} ]] || { echo "desktop_focus: outputs $out_a and $out_b are needed" >&2; exit 2; }

# ---- fixture and probes ----
# The fixture log is appended to across restarts (the key accounting counts lines from a mark).
: >"$fixlog"
start_fixture() { # [arm delay ms]: 0 = OnDemand at the press, as the shell
  local starts last
  starts=$(grep -c "\[df-fixture\] outputs" "$fixlog")
  GF_DF_OUTPUTS="$out_a,$out_b" GF_DF_ARM_DELAY_MS=${1:-0} WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    setsid "$root/scripts/dev/isolated.sh" --name desktop-focus-fixture qs -p "$root/tests/compositor/desktop-focus-fixture" --no-color \
    >>"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  for _ in $(seq 1 50); do
    (($(grep -c "\[df-fixture\] outputs" "$fixlog") > starts)) && break
    sleep 0.1
  done
  sleep 0.8
  last=$(grep "\[df-fixture\] outputs" "$fixlog" | tail -n 1)
  [[ $last == *"$out_a"* && $last == *"$out_b"* ]]
}
stop_fixture() {
  [[ -n $fixture_pid ]] || return 0
  kill "$fixture_pid" 2>/dev/null
  wait "$fixture_pid" 2>/dev/null
  fixture_pid=""
  sleep 0.3
}
start_fixture 0 || { say "setup error: fixture did not map on both outputs (see $fixlog)"; exit 2; }

foot_probe() { # <capture> -> pid; every typed byte goes to <capture> (raw tty, no echo)
  : >"$1"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name desktop-focus foot -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$1" \
    >/dev/null 2>&1 </dev/null &
  echo $!
}
address_of() { # <pid> -> address of its mapped window, waits up to 5 s
  local a="" i
  for i in $(seq 1 50); do
    a=$(nestctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p and .mapped)][0].address // ""')
    [[ -n $a ]] && break
    sleep 0.1
  done
  echo "$a"
}
centre_of() { # <address> <output x> <output y> -> output-local centre of the window's surface
  nestctl -j clients | jq -r --arg a "$1" --argjson mx "$2" --argjson my "$3" \
    '.[] | select(.address == $a) | "\(.at[0] - $mx + (.size[0] / 2 | floor)) \(.at[1] - $my + (.size[1] / 2 | floor))"'
}

# New windows open on the output under the pointer.
cap_a=$run/foot-a.cap
cap_b=$run/foot-b.cap
pointer output "$out_a" abs $((aw / 2)) $((ah / 2)) sleep 50
p=$(foot_probe "$cap_a"); pids+=("$p"); win_a=$(address_of "$p")
pointer output "$out_b" abs $((bw / 2)) $((bh / 2)) sleep 50
p=$(foot_probe "$cap_b"); pids+=("$p"); win_b=$(address_of "$p")
[[ -n $win_a && -n $win_b ]] || { say "setup error: probe windows did not map ($win_a / $win_b)"; exit 2; }
sleep 0.8
read -r a_cx a_cy < <(centre_of "$win_a" "$ax" "$ay")
read -r b_cx b_cy < <(centre_of "$win_b" "$bx" "$by")
# Bare desktop points (left of the centred windows, between the menu bar and the Dock), Dock and menu bar centres.
desk_a="150 $((ah / 2 + 100))"
desk_b="120 $((bh / 2 + 100))"
dock_a="$((aw / 2)) $((ah - 40))"
bar_a="$((aw / 2)) 15"

say "desktop_focus $mode: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), $out_a ${aw}x${ah}+$ax+$ay, $out_b ${bw}x${bh}+$bx+$by"
say "plugin features: $(nestctl -j grassfield | jq -c .features)"
say "probes: A $win_a on $out_a (centre $a_cx,$a_cy), B $win_b on $out_b (centre $b_cx,$b_cy)"

# ---- key accounting ----
mark_fix=0 mark_a=0 mark_b=0
mark() {
  mark_fix=$(wc -l <"$fixlog")
  mark_a=$(stat -c %s "$cap_a")
  mark_b=$(stat -c %s "$cap_b")
}
# Keys the fixture logged since the mark: <kind> (desktop-key|menu-key) <output> -> concatenated characters.
fix_keys() { tail -n +"$((mark_fix + 1))" "$fixlog" | sed -n "s/.*\[df-fixture\] $1 $2 \(.*\)$/\1/p" | tr -d '\n'; }
cap_new() { tail -c +"$(($2 + 1))" "$1" | tr -d '\n'; }
# Where the keys went since the mark: "desktopA=<…> desktopB=<…> menu=<…> footA=<…> footB=<…>"
where() {
  printf 'desktopA=%s desktopB=%s menu=%s%s footA=%s footB=%s' "$(fix_keys desktop-key "$out_a")" "$(fix_keys desktop-key "$out_b")" \
    "$(fix_keys menu-key "$out_a")" "$(fix_keys menu-key "$out_b")" "$(cap_new "$cap_a" "$mark_a")" "$(cap_new "$cap_b" "$mark_b")"
}
# Types <text> now and reports where it went after <ms> ms.
type_now() { # <text> [ms]
  mark
  keys "$1"
  sleep "$(awk -v m="${2:-400}" 'BEGIN { printf "%.3f", m / 1000 }')"
  where
}
click() { # <output> <x> <y> [extra pointer commands...]: move, rest, click, no motion afterwards
  local o=$1 x=$2 y=$3
  shift 3
  pointer output "$o" abs "$x" "$y" sleep 150 click "$@"
}

# Gives the desktop of out_a the keyboard with a click on it (dx, dy: the point). Baseline: plus one pointer motion over
# it, which Hyprland needs without the plugin (the shell's kicker surface emulates it), so that every case starts from
# "the desktop holds the keyboard" in both modes.
focus_desktop() {
  read -r dx dy <<<"$desk_a"
  if [[ $mode == baseline ]]; then
    click "$out_a" "$dx" "$dy" sleep 60 abs $((dx + 4)) $((dy + 4))
  else
    click "$out_a" "$dx" "$dy"
  fi
  sleep 0.4
}

fail=0 passed=0 total=0
check() { # <label> <status> [detail]
  total=$((total + 1))
  if [[ $2 == 0 ]]; then
    passed=$((passed + 1))
    say "  PASS $1${3:+ ($3)}"
  else
    say "  FAIL $1${3:+ ($3)}"
    fail=1
  fi
}

# ---- 7. a waiting desktop grant loses to any other focus path (R13 review of 5706cbd) ----
race_log0=0
race_cases() {
  local dx dy r p p2 cap_c cap_a2 win_c win_a2
  say "case 7: slow desktop commit (OnDemand 700 ms after the press): other focus paths within that time keep the keyboard"
  stop_fixture
  start_fixture 700 || { say "  setup error: the delayed fixture did not start"; return 1; }
  read -r dx dy <<<"$desk_a"
  # A second window on foot A's workspace (it opens over foot A), the target of the focus dispatch below.
  cap_a2=$run/foot-a2.cap
  pointer output "$out_a" abs $((aw / 2)) $((ah / 2)) sleep 50
  p2=$(foot_probe "$cap_a2"); pids+=("$p2")
  win_a2=$(address_of "$p2")
  sleep 0.8
  race_log0=$(grep -ac "" "$hyprlog")
  # 7a a focus dispatch right after the desktop click (what a key binding runs; ALT+TAB itself is not bound for the
  # virtual keyboard in the nested session: foot received ESC TAB).
  click "$out_b" "$b_cx" "$b_cy"; sleep 0.3 # the keyboard starts on foot B, on the other output
  click "$out_a" "$dx" "$dy"
  nestctl dispatch "hl.dsp.focus({ window = \"address:$win_a2\" })" >>"$log" 2>&1
  sleep 1.2 # the delayed on_demand commit (700 ms) is over
  r=$(type_now "ka")
  r="$r footA2=$(cap_new "$cap_a2" 0)"
  [[ -n $win_a2 && $r == *"desktopA= "* && $r == *"footA2=ka"* ]]
  check "7a a focus dispatch right after a desktop click: that window keeps the keys, the late desktop commit does not take them" $? "$r"
  kill "$p2" 2>/dev/null
  sleep 0.5
  # 7b a new window maps right after the desktop click (it takes the keyboard before the desktop commits).
  click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
  cap_c=$run/foot-c.cap
  click "$out_a" "$dx" $((dy + 20))
  p=$(foot_probe "$cap_c"); pids+=("$p")
  win_c=$(address_of "$p")
  sleep 1.2
  r=$(type_now "kn")
  r="$r footC=$(cap_new "$cap_c" 0)"
  [[ -n $win_c && $r == *"desktopA= "* && $r == *"footC=kn"* ]]
  check "7b a window mapping right after a desktop click keeps the keys, the late desktop commit does not take them" $? "$r"
  kill "$p" 2>/dev/null
  sleep 0.5
  # 7c control: without interference the late commit (inside the 1000 ms grant window) still gives the desktop the keys.
  click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
  click "$out_a" "$dx" $((dy + 40))
  sleep 1.2
  r=$(type_now "kc")
  [[ $r == *"desktopA=kc "* && $r == *"footA= "* ]]
  check "7c without interference the late on_demand commit still gives the desktop the keys" $? "$r"
  stop_fixture
  start_fixture 0 || { say "  setup error: the fixture did not restart"; return 1; }
}
# The plugin's log lines for case 7 (Hyprland writes its log late: polled at the end of the run).
race_log_check() {
  local lines="" n=0
  for _ in $(seq 1 100); do
    lines=$(tail -n +"$((race_log0 + 1))" "$hyprlog" | grep -a "desktop-focus: pending grant for desktop .* cancelled" | sed 's/.* cancelled/cancelled/')
    n=$(grep -c . <<<"$lines")
    ((n >= 2)) && break
    sleep 0.1
  done
  ((n >= 2))
  check "7 plugin log: the waiting grants of 7a and 7b were cancelled by the focus change" $? "$(tr '\n' ';' <<<"$lines")"
}

# ---- 8. (function) a click without pointer motion after the menu closed ----
stale_case() {
  local dx dy r
  say "case 8: menu open, pointer onto foot A, Esc, click without motion"
  read -r dx dy <<<"$desk_a"
  click "$out_a" "$a_cx" "$a_cy"; sleep 0.3 # foot A becomes Hyprland's focused window
  focus_desktop
  pointer output "$out_a" abs "$dx" $((dy - 150)) sleep 150 rclick sleep 400
  pointer output "$out_a" abs "$a_cx" "$a_cy" sleep 250 # onto the foot, menu still open, no click
  keys -k Escape
  sleep 0.4
  r=$(type_now "e8"); say "  after Esc (pointer resting on foot A): $r"
  pointer output "$out_a" click # buttons only: no motion event since the popup closed
  sleep 0.3
  r=$(type_now "pf")
  [[ $r == *"footA=pf"* && $r == *"desktopA= "* ]]
  check "8 click on the foot without motion after the menu closed: the foot gets the keys" $? "$r"
}

if [[ $mode == stale ]]; then
  stale_case
  if ((fail == 0)); then say "desktop_focus stale: PASS ($passed/$total checks)"; else say "desktop_focus stale: FAIL ($passed/$total checks passed)"; fi
  say "desktop_focus: log $log"
  exit "$fail"
fi

if [[ $mode == race ]]; then
  race_cases
  race_log_check
  if ((fail == 0)); then say "desktop_focus race: PASS ($passed/$total checks)"; else say "desktop_focus race: FAIL ($passed/$total checks passed)"; fi
  say "desktop_focus: log $log"
  exit "$fail"
fi

if [[ $mode == baseline ]]; then
  plugin_unloaded=1
  nestctl plugin unload "$plugin" >>"$log" 2>&1 || { say "baseline: unload failed"; exit 2; }
  sleep 0.5
  say "baseline: plugin unloaded; the cases below show Hyprland's own behaviour"
fi

# ---- 1. click the last active foot while the desktop holds the keyboard ----
say "case 1: desktop focused, click the last active foot"
click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
r=$(type_now "a"); say "  click foot A, type: $r"
focus_desktop
r=$(type_now "kd"); say "  click desktop, type: $r"
[[ $r == *"desktopA=kd "* ]]
check "1a the desktop gets the keys after a click on it" $? "$r"
click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
r=$(type_now "fa")
[[ $r == *"footA=fa"* && $r == *"desktopA= "* ]]
check "1 click on the last active foot (A) while the desktop holds the keyboard: the foot gets the keys" $? "$r"

# ---- 2. click the desktop and type at once ----
say "case 2: click the desktop, type at once (no pointer motion after the press), 5 rounds"
ok2=0 pre2=0
for i in 1 2 3 4 5; do
  # Foot A gets the keyboard (B first: without the plugin a click on Hyprland's last window would not move it), verified.
  click "$out_b" "$b_cx" "$b_cy"; sleep 0.2
  click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
  r=$(type_now "p" 300)
  [[ $r == *"footA=p"* ]] && pre2=$((pre2 + 1))
  mark
  read -r dx dy <<<"$desk_a"
  click "$out_a" "$dx" $((dy + i * 10))
  keys "z$i"
  sleep 0.4
  r=$(where)
  say "  round $i: $r"
  [[ $r == *"desktopA=z$i "* && $r == *"footA= "* ]] && ok2=$((ok2 + 1))
done
((pre2 == 5 && ok2 == 5))
check "2 click the desktop, type at once: the desktop gets the keys" $? "$ok2/5 rounds, foot A held the keyboard before the click in $pre2/5"

if [[ $mode == check ]]; then
  # ---- 3. hover and presses on the Dock and the menu bar keep the keyboard on the desktop ----
  say "case 3: the desktop keeps the keys over the Dock and the menu bar"
  focus_desktop
  read -r kx ky <<<"$dock_a"
  pointer output "$out_a" abs "$kx" "$ky" sleep 300
  r=$(type_now "hd"); [[ $r == *"desktopA=hd "* ]]; check "3a hover the Dock, type: the desktop keeps the keys" $? "$r"
  read -r mx my <<<"$bar_a"
  pointer output "$out_a" abs "$mx" "$my" sleep 300
  r=$(type_now "hm"); [[ $r == *"desktopA=hm "* ]]; check "3b hover the menu bar, type: the desktop keeps the keys" $? "$r"
  pointer output "$out_a" abs "$a_cx" "$a_cy" sleep 300 # hover a window (no click)
  r=$(type_now "hw"); [[ $r == *"desktopA=hw "* && $r == *"footA= "* ]]; check "3c hover a window, type: the desktop keeps the keys" $? "$r"
  click "$out_a" "$kx" "$ky"; sleep 0.3
  r=$(type_now "pd"); [[ $r == *"desktopA=pd "* ]]; check "3d press on the Dock, type: the desktop keeps the keys" $? "$r"
  click "$out_a" "$mx" "$my"; sleep 0.3
  r=$(type_now "pm"); [[ $r == *"desktopA=pm "* ]]; check "3e press on the menu bar, type: the desktop keeps the keys" $? "$r"
fi

# ---- 4. the last active foot on the other output ----
say "case 4: desktop focused on $out_a, click the last active foot on $out_b"
click "$out_b" "$b_cx" "$b_cy"; sleep 0.3
r=$(type_now "b"); say "  click foot B, type: $r"
focus_desktop
r=$(type_now "dq"); say "  click desktop $out_a, type: $r"
click "$out_b" "$b_cx" "$b_cy"; sleep 0.3
r=$(type_now "fb")
[[ $r == *"footB=fb"* && $r == *"desktopA= "* ]]
check "4 click on the last active foot on the other output: the foot gets the keys" $? "$r"

if [[ $mode == baseline ]]; then
  nestctl plugin load "$plugin" >>"$log" 2>&1
  sleep 0.5
  has_feature && plugin_unloaded=0
  say "baseline: plugin loaded again: $(nestctl -j grassfield 2>/dev/null | jq -c .features)"
  say "baseline: $passed/$total checks passed without the plugin (the policy's cases are expected to fail here)"
  say "desktop_focus: log $log"
  exit 0
fi

# ---- 6. the desktop's popup menu keeps its grab ----
say "case 6: popup menu grab untouched"
focus_desktop
pointer output "$out_a" abs "$dx" $((dy - 150)) sleep 150 rclick sleep 400
r=$(type_now "m"); [[ $r == *"menu=m "* && $r == *"desktopA= "* ]]; check "6a keys go to the open menu (grab)" $? "$r"
mark
keys -k Escape
sleep 0.4
r=$(type_now "e" 500); [[ $r == *"desktopA=e "* ]]; check "6b Esc closes the menu, the keys are back on the desktop" $? "$r"
# The pointer rests where the closed menu was: Hyprland gives it no pointer focus until it moves (Hyprland 0.56.2),
# so move away and back before the second right press.
opened0=$(grep -c "\[df-fixture\] menu $out_a open" "$fixlog")
pointer output "$out_a" abs "$dx" "$dy" sleep 100 abs "$dx" $((dy - 150)) sleep 150 rclick sleep 400
opened1=$(grep -c "\[df-fixture\] menu $out_a open" "$fixlog")
closed0=$(grep -c "\[df-fixture\] menu $out_a closed" "$fixlog")
click "$out_a" "$a_cx" "$a_cy"; sleep 0.4
closed1=$(grep -c "\[df-fixture\] menu $out_a closed" "$fixlog")
r=$(type_now "o"); say "  menu opened ($opened0 -> $opened1), outside click on foot A closed it ($closed0 -> $closed1), type: $r"
((opened1 > opened0 && closed1 > closed0)) && [[ $r != *"footA=o"* ]]
check "6c an outside click on a foot closes the menu and is swallowed (the foot does not get the keyboard)" $? "$r"
click "$out_a" "$a_cx" "$a_cy"; sleep 0.3
r=$(type_now "fc"); [[ $r == *"footA=fc"* ]]; check "6d the next click on that foot gives it the keys" $? "$r"

# ---- 8. a click without pointer motion after the menu closed (shell integration, main 9e76bd7) ----
# Foot A is Hyprland's focused window (clicked just above) while the desktop takes the keyboard; the menu opens away from
# the foot, the pointer moves onto the foot while the menu is open, Esc closes the menu, and the click comes with no motion
# in between: Hyprland's pointer focus is then still the closed popup's surface (or nothing).
stale_case

race_cases

# ---- 5. unload while the desktop holds the keyboard, then load again ----
say "case 5: unload the plugin while the desktop holds the keyboard"
focus_desktop
r=$(type_now "u"); say "  desktop focused before the unload: $r"
w0=$(grep -ac 'grassfield>>{"v":"gfc/1","type":"capabilities","features":\[\]}' "$events")
plugin_unloaded=1
nestctl plugin unload "$plugin" >>"$log" 2>&1
unload_rc=$?
sleep 0.5
kill -0 "$hypr_pid" 2>/dev/null
alive=$?
w1=$(grep -ac 'grassfield>>{"v":"gfc/1","type":"capabilities","features":\[\]}' "$events")
((unload_rc == 0 && alive == 0 && w1 > w0))
check "5a unload while the desktop is focused: Hyprland alive, capabilities withdrawn (empty list posted)" $? "rc $unload_rc, withdrawn events $w0 -> $w1"
r=$(type_now "ux"); [[ $r == *"desktopA=ux "* ]]; check "5b after the unload the keys still reach a live surface (the desktop, nothing stuck)" $? "$r"
click "$out_b" "$b_cx" "$b_cy"; sleep 0.3 # foot B: not Hyprland's last window (A is), so Hyprland's own click focus works
r=$(type_now "uy"); [[ $r == *"footB=uy"* ]]; check "5c after the unload a click on another foot gives it the keys" $? "$r"
nestctl plugin load "$plugin" >>"$log" 2>&1
load_rc=$?
sleep 0.5
has_feature
feat_rc=$?
((load_rc == 0 && feat_rc == 0)) && plugin_unloaded=0
check "5d plugin loaded again and advertises desktop-focus" $((load_rc + feat_rc)) "$(nestctl -j grassfield 2>/dev/null | jq -c .features)"
focus_desktop
click "$out_b" "$b_cx" "$b_cy"; sleep 0.3
r=$(type_now "uz"); [[ $r == *"footB=uz"* && $r == *"desktopA= "* ]]; check "5e after the reload the policy works again (last active foot after the desktop)" $? "$r"

race_log_check

# ---- health ----
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $?
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
((${dumps:-0} == 0))
check "no core dump of the nested Hyprland" $?
exc=$(grep -ac '\[grassfield\] .*exception' "$hyprlog" 2>/dev/null)
((${exc:-0} == 0))
check "no grassfield exception in the nested log" $? "${exc:-0}"
say "desktop-focus log lines in the nested log: $(grep -ac '\[grassfield\] desktop-focus' "$hyprlog" 2>/dev/null)"

if ((fail == 0)); then say "desktop_focus: PASS ($passed/$total checks)"; else say "desktop_focus: FAIL ($passed/$total checks passed)"; fi
say "desktop_focus: log $log"
exit "$fail"
