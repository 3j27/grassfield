#!/usr/bin/env bash
# Nested scenario (L1) for app energy (ADR-0048). Bare command, nested session only. A dev shell decides as a real one but
# only in a dry run on its own state file (.dev/state/app-energy.json): this test reads that file. Two foot windows are
# started each in its own scope under app-graphical.slice, as uwsm-app starts apps (`systemd-run --user --scope`: a transient
# scope in the user manager, which the dry run never changes). Checks:
#   1 B (opened last, focused) is minimized through the shell (`windows minimize`): within 50 s B's scope is recorded as
#     limited (hidden for 30 s: 20/30) and A's (focused now) is not. Needs the machine on battery: on the power adapter
#     nothing is limited (ADR-0048 D-2) and the test stops with exit 2 (environment);
#   2 the overview opens: within 3 s B's scope is no longer limited (woken at once);
#   3 nothing was applied for real: the scopes' CPUWeight is still unset (`systemctl --user show`), and the real state file
#     ($XDG_RUNTIME_DIR/grassfield/app-energy.json) names neither scope.
# The test closes what it opened (EXIT trap). Only this tree's nested instance (scripts/dev/pidfile.sh).
# Expected: "app-energy: 0 failure(s)". Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP app_energy_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "app-energy: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "app-energy: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
command -v foot >/dev/null && command -v jq >/dev/null && command -v systemd-run >/dev/null || { echo "app-energy: foot, jq and systemd-run are needed"; exit 2; }

state=$dev/state/app-energy.json
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" >/dev/null 2>&1; }
wait_for() { local secs=$1 n; shift; for ((n = 0; n < secs * 5; n++)); do "$@" && return 0; sleep 0.2; done; return 1; }
applied() { jq -e --arg u "$1" '.dry == true and ((.apps[$u].applied // {}) | length) > 0' "$state" >/dev/null 2>&1; }
free() { jq -e --arg u "$1" '((.apps[$u].applied // {}) | length) == 0' "$state" >/dev/null 2>&1; }
window() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null; }

tag=gfenergy$$
unit_a=app-$tag-a.scope unit_b=app-$tag-b.scope
cleanup() {
  ipc overview close
  systemctl --user stop "$unit_a" "$unit_b" >/dev/null 2>&1 || true
}
trap cleanup EXIT
start() { # <unit> <app id>
  WAYLAND_DISPLAY=$sock setsid systemd-run --user --scope --quiet --slice=app-graphical.slice --unit="$1" -- \
    "$root/scripts/dev/isolated.sh" foot --app-id "$2" >/dev/null 2>&1 </dev/null &
}
start "$unit_a" "$tag-a"
sleep 1
start "$unit_b" "$tag-b"
wait_for 10 window "$tag-b" || { echo "app-energy: the second window did not open"; exit 2; }
sleep 1
ipc windows minimize
power=$(cat /sys/class/power_supply/*/online 2>/dev/null | sort -u | tr -d '\n')
[[ $power == *1* ]] && { echo "app-energy: on the power adapter nothing is limited (ADR-0048 D-2): unplug it and run again"; exit 2; }

if wait_for 50 applied "$unit_b" && free "$unit_a"; then
  pass "1 the minimized app's scope is limited after its 30 s, the focused one is not ($(jq -c --arg u "$unit_b" '.apps[$u].applied' "$state"))"
else
  fail "1 minimized app not limited within 50 s (state: $(jq -c '.apps' "$state" 2>/dev/null | head -c 400))"
fi

ipc overview open
if wait_for 3 free "$unit_b"; then pass "2 the overview wakes it at once"; else fail "2 still limited 3 s after the overview opened"; fi
ipc overview close

w=$(systemctl --user show -p CPUWeight --value "$unit_b" 2>/dev/null || true)
real=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/grassfield/app-energy.json
if [[ $w == "" || $w == "[not set]" ]] && ! grep -q "$tag" "$real" 2>/dev/null; then
  pass "3 nothing applied for real (CPUWeight ${w:-unset}, the real state file does not name the scopes)"
else
  fail "3 the dry run touched the user manager (CPUWeight=$w) or the real state file"
fi

echo "app-energy: $fails failure(s)"
((fails == 0))
