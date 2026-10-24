#!/usr/bin/env bash
# Nested scenario (L1) for Show Desktop (GF-106, reviews of the shell UX batch). Bare command, nested session only.
#
# Windows: A and B (foot, app id gf-sd-main) and C (foot, app id gf-sd-other) on Space 1; D on Space 2. Every way Show
# Desktop ends is checked for what it must leave behind: every window on its own Space, and the Space and the focus the
# user ended it with (never the old Space or the old focused window, except for the second press):
#   1 show: A, B, C parked on special:desktop, D untouched, record file written;
#   2 second press on the same Space: A, B, C back on Space 1, the Space is 1, the window that had the focus (C) has it;
#   3 Space switch: show, then Space 2: A, B, C back on Space 1, the active Space stays 2, the focus is D (never an old window);
#   4 new window: show, then a new foot E opens: A, B, C back on Space 1, the focus is E;
#   5 activation (the switcher's next/release goes through Compositor.activate, as a Dock click does): show, switcher
#     next + release: every window back, the active window is the one the switcher chose and the Space is its Space.
# 6 (manual) crash recovery: with Show Desktop on, restart the shell (scripts/dev/shell-run.sh): the windows listed in the
#   record file come back to their Space within about two seconds, and nothing is focused by it.
# Only this tree's nested instance (scripts/dev/pidfile.sh); hyprctl is read-only; clients get the nested socket only.
# Expected: "show_desktop: 0 failure(s)" after PASS lines for every check. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "show_desktop: no verified nested instance (scripts/dev/nested-up.sh)"; exit 2; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "show_desktop: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "show_desktop: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
space_of() { hq clients | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .workspace.name'; }
active_pid() { hq activewindow | jq -r '.pid'; }
active_space() { hq activeworkspace | jq -r '.name'; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" >/dev/null 2>&1; }
show_desktop() { ipc windows showDesktop; sleep 1.2; }
space() { "$root/scripts/nestctl" dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1; sleep 1; }
pids=()
open_foot() { # <app id> -> PID of the new window, which also has the focus
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.5
  active_pid
}
cleanup() { for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done; space 1; }
trap cleanup EXIT
# check <what> <window> <wanted Space name>
# Every check waits at most 6 s for the state to arrive (the shell restores from events), then reports what it saw.
wait_for() { local n; for n in $(seq 1 30); do "$@" && return 0; sleep 0.2; done; return 1; }
is_on_space() { [[ $(space_of "$1") == "$2" ]]; }
is_focus() { [[ $(active_pid) == "$1" ]]; }
is_space() { [[ $(active_space) == "$1" ]]; }
on_space() { wait_for is_on_space "$2" "$3" && pass "$1" || fail "$1: window $2 is on $(space_of "$2"), wanted $3"; }
focus_is() { wait_for is_focus "$2" && pass "$1" || fail "$1: focus is $(active_pid), wanted $2"; }
space_is() { wait_for is_space "$2" && pass "$1" || fail "$1: Space is $(active_space), wanted $2"; }
all_home() { # <label>
  on_space "$1: A on Space 1" "$a" 1
  on_space "$1: B on Space 1" "$b" 1
  on_space "$1: C on Space 1" "$c" 1
  on_space "$1: D still on Space 2" "$d" 2
}

space 1
a=$(open_foot gf-sd-main)
b=$(open_foot gf-sd-main)
c=$(open_foot gf-sd-other)
space 2
d=$(open_foot gf-sd-main)
space 1
focus_is "setup: C has the focus on Space 1" "$c"
for p in "$a" "$b" "$c" "$d"; do [[ -n $p && $p != null ]] || { echo "show_desktop: could not open the windows"; exit 2; }; done
# The dev shell keeps its state under .dev/state (shell-run.sh sets GRASSFIELD_STATE_HOME): never the owner's home.
state=$dev/state/show-desktop.json
case $state in "$HOME"/.local/*) echo "show_desktop: the state file would be under $HOME/.local: refusing"; exit 2 ;; esac

# 1 show
show_desktop
for w in "$a" "$b" "$c"; do on_space "1: window $w parked" "$w" special:desktop; done
on_space "1: D on Space 2 is not touched" "$d" 2
has_record() { [[ -s $state ]] && grep -q '"records"' "$state"; }
wait_for has_record && pass "1: the record is in the state dir ($state)" || fail "1: no record in $state"

# 2 second press on the same Space
show_desktop
all_home "2"
space_is "2: the Space is 1" 1
focus_is "2: the window that had the focus (C) has it again" "$c"

# 3 Space switch
show_desktop
space 2
all_home "3"
space_is "3: the Space stays 2 (the user is not pulled back)" 2
focus_is "3: the focus is the Space 2 window" "$d"
space 1

# 4 new window
show_desktop
e=$(open_foot gf-sd-main)
all_home "4"
on_space "4: E stays where it opened" "$e" 1
focus_is "4: the new window keeps the focus" "$e"

# 5 activation (switcher next + release)
space 1
show_desktop
ipc switcher next 7000001
sleep 0.5
ipc switcher release 7000001
all_home "5"
# The front app is gf-sd-main (E); the switcher's next app is gf-sd-other, whose only window is C: C must have the focus.
focus_is "5: the switcher's choice (C, the other app) has the focus, not the old window E" "$c"
space_is "5: the Space is C's Space" 1

echo "show_desktop: $fails failure(s)"
exit $((fails > 0))
