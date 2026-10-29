#!/usr/bin/env bash
# GF-032: an Omarchy update (or a theme or font change) run in a Grassfield session must not start Omarchy's shell next to
# grassfield-shell (second bar, notification server, polkit agent, idle timer, locker). The update ends with
# omarchy-update-restart -> `omarchy-restart-shell`, which kills Omarchy shells and runs `omarchy-launch-shell` through
# Hyprland. Grassfield shadows both names with no-op stand-ins placed first in PATH (config/hypr/grassfield/omarchy.lua
# guard_path for the compositor's children, packaging/uwsm/env-grassfield for the systemd user manager). Omarchy's own
# scripts are never executed here: fake quickshell and hyprctl record every call, and the stand-ins must produce none.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/omarchy-guard.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
shims=$root/packaging/shims
omarchy=${OMARCHY_PATH:-/usr/share/omarchy}

desc="the stand-ins exist for exactly the two commands that start Omarchy's shell, its IPC wrapper and its clamshell helper (the D-12 sleep-lock fail-safe, tests/security/sleep_lock_units.sh), and are executable"
check bash -c '[[ -x "$1/omarchy-restart-shell" && -x "$1/omarchy-launch-shell" && -x "$1/omarchy-shell" && -x "$1/omarchy-hyprland-monitor-clamshell" && $(ls "$1" | wc -l) == 4 ]]' _ "$shims"

# Fake process-starting tools; their log must stay empty.
mkdir -p "$tmp/fake"
for name in quickshell qs hyprctl systemd-cat uwsm-app; do
  printf '#!/bin/sh\necho "%s $*" >>"$FAKE_LOG"\nexit 1\n' "$name" >"$tmp/fake/$name"
  chmod +x "$tmp/fake/$name"
done

# The PATH the compositor hands its children: Omarchy's envs.lua puts its bin first, then Grassfield's guard_path runs.
if command -v lua >/dev/null; then
  guarded_path=$(env -i PATH="/usr/local/bin:/usr/bin" OMARCHY_PATH="$omarchy" HOME="$tmp" lua - "$root" "$shims" <<'LUA'
local repo, shims = arg[1], arg[2]
local envs = {}
hl = setmetatable({ env = function(k, v) envs[k] = v end, config = function() end }, { __index = function() return function() end end })
package.path = repo .. "/config/hypr/?.lua;" .. package.path
local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
-- A failed include (no Omarchy at this path) must still guard: the stand-ins do not depend on it.
m.guard_path(shims)
io.write(envs.PATH)
LUA
  )
  desc="Hyprland's PATH for the session puts the stand-ins first (before Omarchy's bin directory)"
  check bash -c '[[ ${1%%:*} == "$2" ]]' _ "$guarded_path" "$shims"
else
  guarded_path="$shims:/usr/local/bin:/usr/bin"
  echo "SKIP: no Lua interpreter (the PATH built by guard_path is not checked)"
fi

: >"$tmp/log"
desc="with that PATH both names resolve to the stand-ins"
check bash -c 'PATH=$1 && [[ $(command -v omarchy-restart-shell) == "$2/omarchy-restart-shell" && $(command -v omarchy-launch-shell) == "$2/omarchy-launch-shell" ]]' _ "$guarded_path" "$shims"

# What an update does at its end, with the guarded PATH ahead of fake tools: nothing may be started.
desc="omarchy-update-restart's step (omarchy-restart-shell || true) succeeds without starting or killing anything"
status=0
FAKE_LOG=$tmp/log PATH="$shims:$tmp/fake:/usr/bin:/bin" bash -c 'omarchy-restart-shell || true; omarchy-launch-shell' >"$tmp/out" 2>&1 || status=$?
check bash -c '[[ $2 == 0 && ! -s "$1/log" ]] && grep -q "Grassfield session" "$1/out"' _ "$tmp" "$status"

desc="control: without the stand-ins the fake tools are reachable (the test would notice a start)"
FAKE_LOG=$tmp/log PATH="$tmp/fake:/usr/bin:/bin" bash -c 'quickshell kill; hyprctl dispatch x' >/dev/null 2>&1 || true
check test -s "$tmp/log"

desc="the uwsm environment puts the stand-ins first for the systemd user manager (applications started by the Dock)"
check grep -q '^    export PATH="/usr/lib/grassfield/omarchy-shims:\$PATH"$' "$root/packaging/uwsm/env-grassfield"

desc="the session file loads the guard after the Omarchy include (envs.lua prepends Omarchy's bin)"
check bash -c 'inc=$(grep -n "require(\"grassfield.omarchy\")" "$1" | head -1 | cut -d: -f1); g=$(grep -n "guard_path" "$1" | head -1 | cut -d: -f1); [[ -n $inc && -n $g && $g -gt $inc ]]' _ "$root/config/hypr/session.lua"

# Omarchy-side facts the guard relies on (only where Omarchy is installed): the names and the call chain.
if [[ -d $omarchy/bin ]]; then
  desc="Omarchy still calls the restart by that name (omarchy-update-restart), so the stand-in is in the update's path"
  check grep -q 'omarchy-restart-shell' "$omarchy/bin/omarchy-update-restart"
  desc="Omarchy's own commands of the same names still exist (the stand-ins shadow real ones)"
  check bash -c '[[ -e "$1/bin/omarchy-restart-shell" && -e "$1/bin/omarchy-launch-shell" ]]' _ "$omarchy"
  desc="no other Omarchy command starts the shell by another name (only the launcher runs quickshell with the Omarchy config)"
  others=$(grep -Rl 'quickshell -n -p\|qs -n -p' "$omarchy/bin" 2>/dev/null | xargs -r -n1 basename | grep -v '^omarchy-launch-shell$' || true)
  check test -z "$others"
else
  echo "SKIP: Omarchy is not installed here (call chain not checked)"
fi

# A package upgrade (pacman unlinks and recreates /usr/share/grassfield/hypr/*.lua) must not reload the running session:
# the real session's entry file turns Hyprland's file watcher off, the nested dev configuration keeps it (ADR-0001 amendment).
desc="session.lua sets misc.disable_autoreload (an upgrade under a running session left a red error bar, or dropped the bindings)"
check grep -q 'misc = { disable_autoreload = true }' "$root/config/hypr/session.lua"
desc="the nested dev configuration keeps the file watcher (edits of the repository's modules apply at once)"
check bash -c '! grep -q disable_autoreload "$1"' _ "$root/config/hypr/dev.lua"

exit $fail
