#!/usr/bin/env bash
# Nested scenario, gate L4 (lock privacy) plus DT-05 (screen-share protection) and the D-4 lid lock and display
# power-off. Never targets the owner's session; never types anything (no key reaches the lock field, so PAM is never
# involved). The nested session stays LOCKED afterwards (only the owner's password opens it): finish with
# scripts/dev/nested-down.sh.
#
# Usage: tests/security/lock_privacy.sh [step...]   (default: every step, in this order)
#   setup        marker image; on GF-REF, side by side, three foot windows: "gf-privacy-probe" filled with the marker
#                colour (magenta), "gf-privacy-twin" filled with green (unprotected) and "Bitwarden" (protected) with
#                the twin's foot options and size; three notifications whose image is the marker. Fixture self-check
#                before the Bitwarden window opens: a capture must show the probe's magenta and the twin's green. The
#                test's only capture path, grim over Hyprland's capture protocols, honours no_screen_share (that is
#                what DT-05 checks), so the twin is how the test knows that green renders at all. Without that proof
#                every "0 marker px" and "0 green px" check below FAILS instead of passing.
#   screenshare  DT-05 / SEC-01: in a capture of the unlocked desktop the probe is magenta and the twin green (controls),
#                the Bitwarden window's region is black and its box holds no green pixel (Omarchy's no_screen_share
#                rule, config/hypr/grassfield/privacy.lua)
#   control      the probe and twin windows' own regions are magenta and green before locking (not the banners, which
#                expire): the detectors work
#   lock         `lock lid` (D-4: the nested outputs WAYLAND-1 and GF-REF are not external displays, so the lid locks)
#   privacy      L4: while locked, two more notifications (one critical), and every surface IPC can open (Search, Apps,
#                Notification Center, menu bar menu, Overview, Dock menu); captures of both outputs hold no marker
#                and no green pixel (the twin is unprotected window content); Hyprland reports LOCK on every monitor
#   display-off  D-4: with `idle devDisplayOff 4` set before the lock, the shell turns the displays off after 4 s
#                without input (idle status displayOff, Hyprland dpmsStatus) and on again on pointer motion
#   cleanup      close the foot windows (the session stays locked)
# Requires scripts/dev/nested-up.sh (GRASSFIELD_DEV=1 shell on a private bus: notify-send reaches only it).
# Exit status: 0 when every requested step passed.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host lock_privacy
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
[[ $bus == unix:path=/tmp/dbus-* ]] || { echo "lock_privacy: no private bus of the nested shell (.dev/bus.address); run scripts/dev/nested-up.sh" >&2; exit 2; }
# Testing rule after the review of 423766f (a probe once reached the owner's session bus): only the nested shell's
# private bus, never the caller's own, and notify-send runs under `env -i` with that address alone.
[[ $bus != *"/run/user/"* && ( -z ${DBUS_SESSION_BUS_ADDRESS:-} || $bus != "$DBUS_SESSION_BUS_ADDRESS" ) ]] || { echo "lock_privacy: refusing the caller's own session bus ($bus)" >&2; exit 2; }
for tool in grim magick notify-send foot jq awk; do
  command -v "$tool" >/dev/null || { echo "lock_privacy: $tool is not installed" >&2; exit 2; }
done

work=$dev/lock-privacy
mkdir -p "$work"
marker=$work/marker.png
fixture=$work/fixture # key=value lines written by setup: probe, protected (window addresses), proven=1 (self-check)
out=GF-REF            # the output the fixture windows open on, and the one the region checks cut from
win_w=560 win_h=360   # fixture window size (logical px)
inset=16              # a region check skips this border of a window (rounded corners, rims)
status=0
why="" # reason of the last helper failure
nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
ipc() { nested qs ipc -p "$root/shell" call "$@" 2>/dev/null; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
notify() { env -i PATH="$PATH" DBUS_SESSION_BUS_ADDRESS="$bus" notify-send "$@" >/dev/null 2>&1; }

compositor_locked() {
  nested hyprctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}

wait_status() { # <expected> <seconds>
  local want=$1 tries=$(($2 * 4)) got=""
  for _ in $(seq 1 "$tries"); do
    got=$(ipc lock status)
    [[ $got == "$want" ]] && { echo "$got"; return 0; }
    sleep 0.25
  done
  echo "${got:-no-answer}"
  return 1
}

# Pixels of <colour> (8 % fuzz) in a PNG.
count_colour() { # <png> <#rrggbb>
  magick "$1" -alpha off -fuzz 8% -fill black +opaque "$2" -fill white -opaque "$2" -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo error
}

# Fraction (0..1) of the pixels of a PNG within 8 % of <colour>, black included: the matches are first painted a
# sentinel colour, then the sentinel becomes white and everything else black. True colour first: a cut that is all
# black or all grey is stored as a greyscale PNG, where the sentinel would turn grey and match nothing.
colour_frac() { # <png> <#rrggbb>
  magick "$1" -alpha off -colorspace sRGB -type TrueColor -fuzz 8% -fill "#010203" -opaque "$2" -fuzz 0 \
    -fill black +opaque "#010203" -fill white -opaque "#010203" -format '%[fx:mean]' info: 2>/dev/null || echo error
}

at_least() { # <fraction> <minimum>: false for anything that is not a number
  [[ $1 =~ ^[0-9]+(\.[0-9]+)?(e[-+]?[0-9]+)?$ ]] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

near() { # <a> <b> <a0> <b0>: four integers, a within 2 of a0 and b within 2 of b0 (a position or a size)
  local v
  for v in "$@"; do [[ $v =~ ^-?[0-9]+$ ]] || return 1; done
  (($1 - $3 <= 2 && $3 - $1 <= 2 && $2 - $4 <= 2 && $4 - $2 <= 2))
}

# Grabs one output to <png>, never leaving an older file in its place: the captures stay in $work between runs and
# the fixture windows open at the same places every run, so a stale image would pass every check. The file is deleted
# first and must exist, be non-empty and be no older than the grab's start; a failure is reported on stderr.
grab() { # <output> <png>
  local start t
  start=$(date +%s)
  rm -f "$2"
  nested grim -o "$1" "$2" 2>/dev/null || { echo "lock_privacy: grim -o $1 failed ($2)" >&2; return 1; }
  t=$(stat -c %Y "$2" 2>/dev/null) && [[ -s $2 && $t =~ ^[0-9]+$ ]] && ((t >= start)) \
    || { echo "lock_privacy: grim -o $1 left no fresh $2" >&2; return 1; }
}

# Captures both nested outputs (GF-REF headless reference, WAYLAND-1 window) to $work/<name>-<output>.png: prints
# "<magenta> <green>" summed, or "error error" when a grab or a count fails (the callers then FAIL).
capture() { # <name>
  local output png m=0 g=0 c
  for output in GF-REF WAYLAND-1; do
    png=$work/$1-$output.png
    grab "$output" "$png" || { echo "error error"; return; }
    c=$(count_colour "$png" "#ff00ff"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error"; return; }
    m=$((m + c))
    c=$(count_colour "$png" "#00ff00"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error"; return; }
    g=$((g + c))
  done
  echo "$m $g"
}

mon_x="" mon_y="" mon_w="" mon_h="" mon_scale=""
monitor_load() { # position and logical size of $out (layout px) and its scale; sets why on failure
  read -r mon_x mon_y mon_w mon_h mon_scale < <(nested hyprctl -j monitors 2>/dev/null | jq -r --arg o "$out" \
    '.[] | select(.name == $o) | "\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor) \(.scale)"')
  [[ ${mon_w:-} =~ ^[0-9]+$ && ${mon_h:-} =~ ^[0-9]+$ ]] || { why="Hyprland lists no monitor $out"; return 1; }
}

client_info() { # <address> -> "<x> <y> <w> <h> <class> <pid>" (layout px); nothing when that window is gone
  [[ -n $1 ]] || return 0
  nested hyprctl -j clients 2>/dev/null | jq -r --arg a "$1" \
    '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.class) \(.pid)"' | head -n 1
}

class_present() { # <class>
  nested hyprctl -j clients 2>/dev/null | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null
}

fixture_get() { # <key>: the last value setup wrote
  [[ -s $fixture ]] && sed -n "s/^$1=//p" "$fixture" | tail -n 1
}

# The fixture record was written by a setup in this nested instance (it stays in $work between runs and sessions).
fixture_ours() {
  [[ $(fixture_get instance) == "$sig" ]] || { why="no setup ran in this nested session (setup step)"; return 1; }
}

# Succeeds when the setup's self-check passed in this session and its probe, twin and Bitwarden windows are still
# open; sets why otherwise.
fixture_proven() {
  fixture_ours || return 1
  [[ $(fixture_get proven) == 1 ]] || { why="the fixture self-check did not pass (setup step)"; return 1; }
  [[ $(client_info "$(fixture_get probe)") == *" gf-privacy-probe "* ]] || { why="the self-checked probe window is gone"; return 1; }
  [[ $(client_info "$(fixture_get twin)") == *" gf-privacy-twin "* ]] || { why="the self-checked green twin window is gone"; return 1; }
  [[ $(client_info "$(fixture_get protected)") == *" Bitwarden "* ]] || { why="the self-checked Bitwarden window is gone"; return 1; }
}

# The inner part of a window (its box minus <inset>, default $inset, on each side) cut from a capture of $out to
# $work/<name>.png and measured for <colour>: prints "<fraction> <colour at its centre>", or "error none" (window
# gone, cut failed).
region() { # <capture png> <window address> <name> <#rrggbb> [<inset>]
  local x y w h png=$work/$3.png geometry centre i=${5:-$inset}
  read -r x y w h _ < <(client_info "$2")
  rm -f "$png"
  [[ ${h:-} =~ ^[0-9]+$ ]] && ((w > 2 * i && h > 2 * i)) || { echo "error none"; return; }
  geometry=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mon_x" -v my="$mon_y" -v s="$mon_scale" -v i="$i" \
    'BEGIN { printf "%dx%d+%d+%d", (w - 2 * i) * s, (h - 2 * i) * s, (x - mx + i) * s, (y - my + i) * s }')
  magick "$1" -crop "$geometry" +repage "$png" 2>/dev/null || { echo "error none"; return; }
  centre=$(magick "$png" -alpha off -gravity center -crop 1x1+0+0 +repage -format '#%[hex:p{0,0}]' info: 2>/dev/null) || centre=none
  echo "$(colour_frac "$png" "$4") ${centre:-none}"
}

# Waits for windows to show their colours: grabs $out until each <address> <colour> pair covers at least 0.9 of the
# window's region, at most 6 times (new windows and moves animate). Cheap (region cuts only); the checks that decide
# run on a capture taken afterwards.
settle() { # <name> <address> <#rrggbb> [<address> <#rrggbb>...]
  local name=$1 png f k ok
  shift
  local -a pairs=("$@")
  png=$work/$name-settle-$out.png
  for _ in $(seq 1 6); do
    ok=0
    if grab "$out" "$png" 2>/dev/null; then
      ok=1
      for ((k = 0; k + 1 < ${#pairs[@]}; k += 2)); do
        read -r f _ < <(region "$png" "${pairs[k]}" "$name-settle" "${pairs[k + 1]}")
        at_least "$f" 0.9 || { ok=0; break; }
      done
    fi
    ((ok)) && return 0
    sleep 0.5
  done
  return 1
}

# True when the two windows' boxes, each with the 48 px band above it (titlebar, shadow), share no pixel.
apart() { # <address> <address>
  local ax ay aw ah bx by bw bh
  read -r ax ay aw ah _ < <(client_info "$1")
  read -r bx by bw bh _ < <(client_info "$2")
  [[ ${ah:-} =~ ^[0-9]+$ && ${bh:-} =~ ^[0-9]+$ ]] || return 1
  ! ((ax < bx + bw && bx < ax + aw && ay - 48 < by + bh && by - 48 < ay + ah))
}

# foot's colour options. foot 1.28 (installed 2026-10-16) reads [colors-dark] and [colors-light] only: an override of
# the older [colors] section is a config error that foot reports and then ignores, so the window opens in its default
# colours (black). Both themes get the same colour (whichever foot starts in), alpha 1 (no wallpaper through). An older
# foot that knows only [colors] gets that spelling. Each set is checked with `foot --check-config` (exit 230 on any
# config error, no window) before a window opens.
foot_style=""
foot_check() { # <foot options...>: prints foot's config errors and fails when foot rejects them
  env -u WAYLAND_DISPLAY "$root/scripts/dev/isolated.sh" foot --check-config "$@" 2>&1 >/dev/null
}
colour_opts() { # <rrggbb>: sets the array opts
  case $foot_style in
    dark-light) opts=(-o "colors-dark.background=$1" -o "colors-dark.foreground=$1" -o colors-dark.alpha=1
      -o "colors-light.background=$1" -o "colors-light.foreground=$1" -o colors-light.alpha=1) ;;
    legacy) opts=(-o "colors.background=$1" -o "colors.foreground=$1" -o colors.alpha=1) ;;
    *) opts=() ;;
  esac
}
detect_foot_style() {
  if foot_check -o colors-dark.background=000000 -o colors-light.background=000000 >/dev/null; then
    foot_style=dark-light
  elif foot_check -o colors.background=000000 >/dev/null; then
    foot_style=legacy
  else
    return 1
  fi
}

# Opens a ${win_w}x${win_h} foot window filled with <rrggbb> (no text, no cursor) and moves it to <x>,<y> of $out
# (logical px). Sets win_addr; sets why on failure. Windows open centred under the pointer, so without the move the
# second fixture window would cover the first.
win_addr=""
foot_window() { # <app id> <rrggbb> <x> <y>
  local opts err pid addr="" cpid="" x="" y="" tx=$((mon_x + $3)) ty=$((mon_y + $4))
  win_addr=""
  [[ -n $foot_style ]] || detect_foot_style || { why="foot accepts neither [colors-dark] nor [colors] colour overrides"; return 1; }
  colour_opts "$2"
  err=$(foot_check "${opts[@]}") || { why="foot rejects the colour options ${opts[*]}: $err"; return 1; }
  class_present "$1" && { why="a $1 window is already open (an earlier run?): restart the nested session (nested-down, nested-up)"; return 1; }
  # Not through nested(): a shell function sent to the background runs in a subshell, and $! would name that subshell
  # (stopping it leaves foot open). Here $! is foot itself, the leader of its own session (setsid).
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" setsid "$root/scripts/dev/isolated.sh" foot --app-id="$1" \
    --window-size-pixels="${win_w}x${win_h}" "${opts[@]}" -- sh -c 'printf "\033[?25l"; exec sleep 3600' >/dev/null 2>&1 </dev/null &
  pid=$!
  dev_record_pid "$dev/privacy-$1.pid" "$pid"
  for _ in $(seq 1 40); do
    addr=$(nested hyprctl -j clients 2>/dev/null | jq -r --arg c "$1" '[.[] | select(.class == $c)] | first | .address // empty')
    [[ -n $addr ]] && break
    sleep 0.25
  done
  [[ -n $addr ]] || { why="no $1 window appeared"; return 1; }
  # The record must name the process that owns the window: the window's own pid when it is another foot.
  read -r _ _ _ _ _ cpid < <(client_info "$addr")
  [[ ${cpid:-} =~ ^[0-9]+$ && $cpid != "$pid" && $(cat "/proc/$cpid/comm" 2>/dev/null) == foot ]] && dev_record_pid "$dev/privacy-$1.pid" "$cpid"
  "$root/scripts/nestctl" dispatch "hl.dsp.window.move({ x = $tx, y = $ty, window = 'address:$addr' })" >/dev/null 2>&1
  for _ in $(seq 1 20); do
    read -r x y _ < <(client_info "$addr")
    near "$x" "$y" "$tx" "$ty" && break
    sleep 0.15
  done
  near "$x" "$y" "$tx" "$ty" \
    || { why="the $1 window did not move to ($3,$4) of $out (it is at ${x:-?},${y:-?} in layout px, target $tx,$ty)"; return 1; }
  win_addr=$addr
}

step_setup() {
  local gap y x0 x1 x2 probe twin protected i m="" g="" pm="error" pc="none" gm="error" gc="none" ok=1 bx by bw bh
  rm -f "$fixture"
  echo "instance=$sig" >>"$fixture"
  magick -size 64x64 xc:"#ff00ff" "$marker" || { fail "setup: cannot draw the marker image"; return; }
  monitor_load || { fail "setup: $why"; return; }
  # Three columns: probe, twin, Bitwarden.
  gap=$(((mon_w - 3 * win_w) / 4)) y=$(((mon_h - win_h) / 2))
  x0=$gap x1=$((2 * gap + win_w)) x2=$((3 * gap + 2 * win_w))
  ((gap >= 32 && mon_h >= win_h + 200)) \
    || { fail "setup: $out (${mon_w}x${mon_h}) has no room for three ${win_w}x${win_h} windows side by side"; return; }
  # New windows open on the output under the pointer; it rests on bare desktop below the row (not on the Dock).
  "$root/scripts/dev/pointer.sh" output "$out" abs $((mon_w / 2)) $((y + win_h + 80)) >/dev/null
  foot_window gf-privacy-probe ff00ff "$x0" "$y" || { fail "setup: marker window: $why"; return; }
  probe=$win_addr
  echo "probe=$probe" >>"$fixture"
  pass "setup: marker window (gf-privacy-probe) at ($x0,$y) of $out"
  foot_window gf-privacy-twin 00ff00 "$x1" "$y" || { fail "setup: twin window: $why"; return; }
  twin=$win_addr
  echo "twin=$twin" >>"$fixture"
  apart "$probe" "$twin" || { fail "setup: the probe and twin windows overlap: $(client_info "$probe") / $(client_info "$twin")"; return; }

  # Self-check: each fixture colour renders, read in the windows' own regions (not the banners).
  settle selfcheck "$probe" "#ff00ff" "$twin" "#00ff00" || true
  read -r m g < <(capture selfcheck)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "setup: self-check: the capture failed (no fresh $work/selfcheck-*.png), nothing is proven"; return; }
  read -r pm pc < <(region "$work/selfcheck-$out.png" "$probe" selfcheck-probe "#ff00ff")
  read -r gm gc < <(region "$work/selfcheck-$out.png" "$twin" selfcheck-twin "#00ff00")
  echo "self-check capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc); both outputs: magenta $m px, green $g px ($work/selfcheck-*.png)"
  at_least "$pm" 0.9 || { fail "setup: self-check: the probe window is not magenta ($pm of its region, centre $pc): every marker check would prove nothing"; ok=0; }
  at_least "$gm" 0.9 || { fail "setup: self-check: the unprotected twin is not green ($gm of its region, centre $gc): every green check would pass vacuously"; ok=0; }
  ((ok)) || return
  pass "setup: self-check: the probe window renders magenta ($pm of its region), an unprotected green window renders green ($gm)"

  # The Bitwarden window: the twin's foot options and size, only the app id differs. The twin stays open through the
  # lock: it is the unprotected window content the "0 green px" check on the lock screen is about.
  foot_window Bitwarden 00ff00 "$x2" "$y" || { fail "setup: protected window: $why"; return; }
  protected=$win_addr
  read -r bx by bw bh _ < <(client_info "$protected")
  apart "$probe" "$protected" && apart "$twin" "$protected" \
    || { fail "setup: the Bitwarden window overlaps the probe or the twin: $(client_info "$protected")"; return; }
  echo "protected=$protected" >>"$fixture"
  echo "proven=1" >>"$fixture"
  pass "setup: protected window (app id Bitwarden, the twin's options and size) at ($((bx - mon_x)),$((by - mon_y))) of $out, ${bw}x${bh}"

  for i in 1 2 3; do
    notify -i "$marker" -h "string:image-path:$marker" "L4 privacy $i" "token-$RANDOM$RANDOM"
  done
  sleep 1
  echo "notifications: $(ipc notifications status)"
}

step_screenshare() {
  local m="" g="" pm pc gm gc bk bc bg probe twin protected
  fixture_proven || { fail "screenshare: $why: the screen-share checks would prove nothing"; return; }
  monitor_load || { fail "screenshare: $why"; return; }
  probe=$(fixture_get probe) twin=$(fixture_get twin) protected=$(fixture_get protected)
  settle screenshare "$probe" "#ff00ff" "$twin" "#00ff00" "$protected" "#000000" || true
  read -r m g < <(capture screenshare)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "screenshare: the capture failed (no fresh $work/screenshare-*.png)"; return; }
  read -r pm pc < <(region "$work/screenshare-$out.png" "$probe" screenshare-probe "#ff00ff")
  read -r gm gc < <(region "$work/screenshare-$out.png" "$twin" screenshare-twin "#00ff00")
  read -r bk bc < <(region "$work/screenshare-$out.png" "$protected" screenshare-bitwarden "#000000")
  # Green anywhere in the Bitwarden window's whole box (no inset): its own pixels leaking.
  read -r _ _ < <(region "$work/screenshare-$out.png" "$protected" screenshare-bitwarden-box "#00ff00" 0)
  bg=$(count_colour "$work/screenshare-bitwarden-box.png" "#00ff00")
  echo "screenshare capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc), Bitwarden region black $bk (centre $bc), green px in the Bitwarden box $bg; both outputs: magenta $m px, green $g px ($work/screenshare-*.png)"
  at_least "$pm" 0.9 && pass "screenshare: the unprotected probe window is captured (control: $pm of its region magenta)" \
    || fail "screenshare: the probe window is not captured ($pm of its region magenta, centre $pc)"
  at_least "$gm" 0.9 && pass "screenshare: the unprotected green twin is captured green (control: $gm of its region)" \
    || fail "screenshare: the green twin is not captured green ($gm of its region, centre $gc): the green check would prove nothing"
  at_least "$bk" 0.9 && pass "screenshare: the Bitwarden window is black in the capture ($bk of its region)" \
    || fail "screenshare: the Bitwarden window's region is not black ($bk, centre $bc) (SEC-01)"
  [[ $bg == 0 ]] && pass "screenshare: no green pixel of the Bitwarden window is captured (its twin, same options, is)" \
    || fail "screenshare: ${bg} green px of the Bitwarden window were captured (SEC-01)"
}

step_control() {
  local m="" g="" pm pc gm gc probe twin
  monitor_load || { fail "control: $why"; return; }
  fixture_ours || { fail "control: $why"; return; }
  probe=$(fixture_get probe) twin=$(fixture_get twin)
  [[ $(client_info "$probe") == *" gf-privacy-probe "* ]] || { fail "control: no probe window (run the setup step first)"; return; }
  [[ $(client_info "$twin") == *" gf-privacy-twin "* ]] || { fail "control: no green twin window (run the setup step first)"; return; }
  settle control "$probe" "#ff00ff" "$twin" "#00ff00" || true
  read -r m g < <(capture control)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "control: the capture failed (no fresh $work/control-*.png)"; return; }
  read -r pm pc < <(region "$work/control-$out.png" "$probe" control-probe "#ff00ff")
  read -r gm gc < <(region "$work/control-$out.png" "$twin" control-twin "#00ff00")
  echo "control capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc); both outputs, banners included: magenta $m px, green $g px ($work/control-*.png)"
  at_least "$pm" 0.9 && pass "control: the probe window shows the marker colour before the lock ($pm of its region): the detector works" \
    || fail "control: the probe window is not magenta before the lock ($pm of its region, centre $pc): the privacy check would prove nothing"
  at_least "$gm" 0.9 && pass "control: the unprotected green twin shows green before the lock ($gm of its region)" \
    || fail "control: the green twin is not green before the lock ($gm of its region, centre $gc): the green check would prove nothing"
}

step_lock() {
  local answer s
  echo "idle devDisplayOff 4 -> $(ipc idle devDisplayOff 4)"
  answer=$(ipc lock lid)
  echo "lock lid -> $answer"
  [[ $answer == ok ]] && pass "lock: the lid locks with no external display (nested outputs)" || fail "lock: lock lid answered '$answer'"
  if s=$(wait_status locked 10); then pass "lock: status $s"; else fail "lock: status $s"; fi
  for _ in $(seq 1 40); do compositor_locked && break; sleep 0.1; done
  compositor_locked && pass "lock: Hyprland reports LOCK on every monitor" || fail "lock: Hyprland does not report LOCK"
}

step_privacy() {
  local m g proven=1
  fixture_proven || proven=0
  notify -i "$marker" -h "string:image-path:$marker" "L4 privacy while locked" "token-$RANDOM"
  notify -u critical -i "$marker" -h "string:image-path:$marker" "L4 privacy critical" "token-$RANDOM"
  # Every surface IPC can open (dev hooks and actions alike): none may show over the lock.
  ipc search open privacy >/dev/null
  ipc apps open >/dev/null
  ipc notifications toggleCenter >/dev/null
  ipc menubar open system "" >/dev/null
  ipc overview open >/dev/null
  ipc dock menu 0 "" >/dev/null
  sleep 1.5
  read -r m g < <(capture privacy)
  echo "privacy capture: magenta $m, green $g ($work/privacy-*.png)"
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "privacy: the capture failed (no fresh $work/privacy-*.png)"; return; }
  if ((m != 0)); then
    fail "privacy: $m marker pixels on the lock screen (notification or window content visible, L4)"
  elif ((proven)); then
    pass "privacy: no notification image, banner or window content on the lock screen (0 marker px)"
  else
    fail "privacy: 0 marker px proves nothing: $why"
  fi
  if ((g != 0)); then
    fail "privacy: $g green px on the lock screen (the unprotected twin's content is visible, L4)"
  elif ((proven)); then
    pass "privacy: no window content: the unprotected green twin is hidden (0 green px)"
  else
    fail "privacy: 0 green px proves nothing: $why"
  fi
  compositor_locked && pass "privacy: still locked (LOCK on every monitor)" || fail "privacy: Hyprland no longer reports LOCK"
}

dpms_all() { # <true|false>: every monitor's dpmsStatus
  nested hyprctl -j monitors 2>/dev/null | jq -e --argjson v "$1" 'length > 0 and all(.[]; .dpmsStatus == $v)' >/dev/null
}

step_display_off() {
  local st off=""
  for _ in $(seq 1 40); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == true ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: displays turned off after 4 s without input on the lock screen" || fail "display-off: idle status $st"
  dpms_all false && pass "display-off: Hyprland reports every display off (dpmsStatus false)" || echo "display-off: dpmsStatus $(nested hyprctl -j monitors | jq -c '[.[] | {name, dpmsStatus}]') (informational on nested outputs)"
  "$root/scripts/dev/pointer.sh" output GF-REF abs 800 500 sleep 100 abs 820 520 >/dev/null
  off=""
  for _ in $(seq 1 20); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == false ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: pointer motion turns the displays on again" || fail "display-off: still off after input: $st"
  dpms_all true && pass "display-off: Hyprland reports every display on" || fail "display-off: dpmsStatus $(nested hyprctl -j monitors | jq -c '[.[] | {name, dpmsStatus}]')"
  compositor_locked && pass "display-off: still locked" || fail "display-off: Hyprland no longer reports LOCK"
}

step_cleanup() {
  local id
  for id in gf-privacy-probe gf-privacy-twin Bitwarden; do
    dev_stop "$dev/privacy-$id.pid" "privacy $id foot" >/dev/null || true
  done
  rm -f "$fixture"
  echo "captures kept in $work; the nested session stays locked (scripts/dev/nested-down.sh)"
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup screenshare control lock privacy display-off cleanup)
[[ $(ipc lock status) == unlocked || " ${steps[*]} " != *" lock "* ]] \
  || { echo "lock_privacy: the nested session is already locked; restart it (nested-down, nested-up) for the default run" >&2; exit 2; }
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "lock_privacy: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
done
exit $status
