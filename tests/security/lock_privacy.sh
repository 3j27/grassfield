#!/usr/bin/env bash
# Nested scenario, gate L4 (lock privacy) plus DT-05 (screen-share protection) and the D-4 lid lock and display
# power-off. Never targets the owner's session; never types anything (no key reaches the lock field, so PAM is never
# involved). The nested session stays LOCKED afterwards (only the owner's password opens it): finish with
# scripts/dev/nested-down.sh.
#
# Usage: tests/security/lock_privacy.sh [step...]   (default: every step, in this order)
#   setup        marker image, two foot windows: "gf-privacy-probe" filled with the marker colour (magenta) and
#                "Bitwarden" filled with green; three notifications whose image is the marker
#   screenshare  DT-05 / SEC-01: in a capture of the unlocked desktop the magenta window shows (control) and no green
#                pixel does (the Bitwarden window is black: Omarchy's no_screen_share rule, config/hypr/grassfield/privacy.lua)
#   control      the marker colour is visible before locking (banners and the probe window): the detector works
#   lock         `lock lid` (D-4: the nested outputs WAYLAND-1 and GF-REF are not external displays, so the lid locks)
#   privacy      L4: while locked, two more notifications (one critical), and every surface IPC can open (Search, Apps,
#                Notification Center, menu bar menu, Overview, Dock menu); captures of both outputs hold no marker
#                and no green pixel; Hyprland reports LOCK on every monitor
#   display-off  D-4: with `idle devDisplayOff 4` set before the lock, the shell turns the displays off after 4 s
#                without input (idle status displayOff, Hyprland dpmsStatus) and on again on pointer motion
#   cleanup      close the two foot windows (the session stays locked)
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
for tool in grim magick notify-send foot jq; do
  command -v "$tool" >/dev/null || { echo "lock_privacy: $tool is not installed" >&2; exit 2; }
done

work=$dev/lock-privacy
mkdir -p "$work"
marker=$work/marker.png
status=0
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

# Captures both nested outputs (GF-REF headless reference, WAYLAND-1 window): prints "<magenta> <green>" summed.
capture() { # <name>
  local out m=0 g=0 c
  for output in GF-REF WAYLAND-1; do
    out=$work/$1-$output.png
    nested grim -o "$output" "$out" 2>/dev/null || { echo "error error"; return; }
    c=$(count_colour "$out" "#ff00ff"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error"; return; }
    m=$((m + c))
    c=$(count_colour "$out" "#00ff00"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error"; return; }
    g=$((g + c))
  done
  echo "$m $g"
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

foot_window() { # <app id> <rrggbb>
  local opts err
  [[ -n $foot_style ]] || detect_foot_style || { echo "foot accepts neither [colors-dark] nor [colors] colour overrides" >&2; return 1; }
  colour_opts "$2"
  err=$(foot_check "${opts[@]}") || { echo "foot rejects the colour options ${opts[*]}: $err" >&2; return 1; }
  nested setsid "$root/scripts/dev/isolated.sh" foot --app-id="$1" "${opts[@]}" \
    -- sh -c 'printf "\033[?25l"; exec sleep 3600' >/dev/null 2>&1 </dev/null &
  dev_record_pid "$dev/privacy-$1.pid" "$!"
  for _ in $(seq 1 40); do
    nested hyprctl -j clients 2>/dev/null | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null && return 0
    sleep 0.25
  done
  return 1
}

step_setup() {
  magick -size 64x64 xc:"#ff00ff" "$marker" || { fail "setup: cannot draw the marker image"; return; }
  "$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
  foot_window gf-privacy-probe ff00ff && pass "setup: marker window (gf-privacy-probe)" || fail "setup: marker window did not appear"
  "$root/scripts/dev/pointer.sh" output GF-REF abs 700 400 >/dev/null
  foot_window Bitwarden 00ff00 && pass "setup: protected window (app id Bitwarden)" || fail "setup: Bitwarden window did not appear"
  local i
  for i in 1 2 3; do
    notify -i "$marker" -h "string:image-path:$marker" "L4 privacy $i" "token-$RANDOM$RANDOM"
  done
  sleep 1
  echo "notifications: $(ipc notifications status)"
}

step_screenshare() {
  local m g
  read -r m g < <(capture screenshare)
  echo "screenshare capture: magenta $m, green $g ($work/screenshare-*.png)"
  [[ $m =~ ^[0-9]+$ ]] || { fail "screenshare: capture failed"; return; }
  ((m > 500)) && pass "screenshare: the unprotected marker window is captured (control: $m px)" || fail "screenshare: control window not captured ($m px)"
  ((g == 0)) && pass "screenshare: the Bitwarden window is hidden from the capture (0 green px)" || fail "screenshare: $g green px of the Bitwarden window were captured (SEC-01)"
}

step_control() {
  local m g
  read -r m g < <(capture control)
  echo "control capture: magenta $m ($work/control-*.png)"
  [[ $m =~ ^[0-9]+$ ]] && ((m > 500)) && pass "control: marker visible before the lock ($m px): the detector works" \
    || fail "control: marker not visible before the lock ($m px): the privacy check would prove nothing"
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
  local m g
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
  [[ $m =~ ^[0-9]+$ ]] || { fail "privacy: capture failed"; return; }
  ((m == 0)) && pass "privacy: no notification image, banner or window content on the lock screen (0 marker px)" \
    || fail "privacy: $m marker pixels on the lock screen (notification or window content visible, L4)"
  ((g == 0)) && pass "privacy: no window content (0 green px)" || fail "privacy: $g green px on the lock screen"
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
  dev_stop "$dev/privacy-gf-privacy-probe.pid" "privacy probe foot" >/dev/null || true
  dev_stop "$dev/privacy-Bitwarden.pid" "Bitwarden probe foot" >/dev/null || true
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
