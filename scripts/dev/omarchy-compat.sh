#!/usr/bin/env bash
# Grassfield's dependencies on Omarchy's private paths, commands, units and files (docs/compat.md, "Omarchy dependencies").
# Fails (exit 1) when one of them is gone or changed in a way Grassfield relies on: run it after every Omarchy update,
# before a release, and (as tests/shell/omarchy_compat.sh) with the test suite. Read-only: no Omarchy command is executed.
#
#   scripts/dev/omarchy-compat.sh [--require]
#
# Without Omarchy installed it prints SKIP and exits 0, unless --require (release check) is given.
#
# Test hooks (defaults are the system paths): OMARCHY_PATH, OMARCHY_COMPAT_UNITS, OMARCHY_COMPAT_SESSIONS,
# OMARCHY_COMPAT_SDDM_THEME, OMARCHY_COMPAT_PAM, OMARCHY_COMPAT_HYPR_STUBS.
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
omarchy=${OMARCHY_PATH:-/usr/share/omarchy}
units=${OMARCHY_COMPAT_UNITS:-/usr/lib/systemd/user}
sessions=${OMARCHY_COMPAT_SESSIONS:-/usr/local/share/wayland-sessions}
theme=${OMARCHY_COMPAT_SDDM_THEME:-/usr/share/sddm/themes/omarchy/Main.qml}
pam=${OMARCHY_COMPAT_PAM:-/etc/pam.d}
stubs=${OMARCHY_COMPAT_HYPR_STUBS:-/usr/share/hypr/stubs/hl.meta.lua}
require=0
[[ ${1:-} == --require ]] && require=1

if [[ ! -d $omarchy/default/hypr && ! -d $omarchy/bin ]]; then
  if ((require)); then echo "FAIL: Omarchy is not installed at $omarchy"; exit 1; fi
  echo "SKIP: Omarchy is not installed at $omarchy (use --require to fail)"
  exit 0
fi

fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
info() { echo "info: $*"; }
# have <what> <test...>: run a test, report ok/FAIL with the dependency's description.
have() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has_grep() { grep -q -- "$1" "$2" 2>/dev/null; }

# --- Hyprland Lua modules loaded by config/hypr/grassfield/omarchy.lua ------------------------------------------------
for m in helpers envs paths require_optional nvidia input; do
  have "Lua module default/hypr/$m.lua (required by the session include)" test -r "$omarchy/default/hypr/$m.lua"
done
have "helpers.lua still defines o.window (default input.lua and Omarchy's app rules call it)" has_grep 'function o.window\|o.window *=' "$omarchy/default/hypr/helpers.lua"
have "input.lua still reads the layout from /etc/vconsole.conf (XKBLAYOUT) and sets compose:caps" bash -c 'grep -q XKBLAYOUT "$1" && grep -q "compose:caps" "$1"' _ "$omarchy/default/hypr/input.lua"
have "envs.lua still sets OMARCHY_PATH and the Wayland environment the shell and apps expect" bash -c 'grep -q OMARCHY_PATH "$1" && grep -q QT_QPA_PLATFORM "$1"' _ "$omarchy/default/hypr/envs.lua"

# --- Commands Grassfield runs or shadows ------------------------------------------------------------------------------
for c in omarchy-restart-shell omarchy-launch-shell; do
  have "$c exists (Grassfield shadows it with a stand-in, packaging/shims)" test -x "$omarchy/bin/$c"
done
have "omarchy-update-restart still restarts the shell by the name omarchy-restart-shell (the stand-in is in the update's path)" has_grep omarchy-restart-shell "$omarchy/bin/omarchy-update-restart"
have "omarchy-launch-shell is still the only command that starts the Omarchy shell (quickshell -n -p)" bash -c '[[ $(grep -Rl "quickshell -n -p" "$1/bin" 2>/dev/null | wc -l) == 1 ]] && grep -Rq "quickshell -n -p" "$1/bin/omarchy-launch-shell"' _ "$omarchy"
for c in omarchy-capture-screenshot omarchy-capture-region omarchy-hook omarchy-powerprofiles-init omarchy-powerprofiles-set omarchy-migrate omarchy-launch-floating-terminal-with-presentation omarchy-migrate-notify; do
  have "command $c exists (used by screenshots, hooks, power profile, migration notice)" test -x "$omarchy/bin/$c"
done
have "omarchy-capture-screenshot still takes the modes fullscreen, region and smart" bash -c 'grep -q "smart" "$1" && grep -q "region" "$1" && grep -q "fullscreen" "$1"' _ "$omarchy/bin/omarchy-capture-screenshot"
have "omarchy-migrate still has --pending (the migration notice asks it)" has_grep '--pending' "$omarchy/bin/omarchy-migrate"
have "omarchy-hook still runs ~/.config/omarchy/hooks/<name>(.d)" has_grep 'config/omarchy/hooks' "$omarchy/bin/omarchy-hook"
# D-12 fail-safe: Grassfield's omarchy-shell stand-in answers exactly these two calls and this status contract.
have "omarchy-system-sleep-lock still asks 'lock lock' through omarchy-shell (Grassfield stand-in)" has_grep 'lock_ipc "$lock_timeout_ms" lock lock' "$omarchy/bin/omarchy-system-sleep-lock"
have "omarchy-system-sleep-lock still polls 'lock status' for .secure/.requested" has_grep 'if .secure == true then "secure"' "$omarchy/bin/omarchy-system-sleep-lock"
have "omarchy-system-sleep-lock still calls omarchy-hyprland-monitor-clamshell by name (Grassfield stand-in)" has_grep 'omarchy-hyprland-monitor-clamshell' "$omarchy/bin/omarchy-system-sleep-lock"

# --- User units that Grassfield's drop-ins and replacements target ----------------------------------------------------
for u in omarchy-sleep-lock omarchy-crash-watch omarchy-migrate-notify; do
  have "user unit $u.service exists (Grassfield's drop-in keeps it out of the session)" test -r "$units/$u.service"
done
[[ -r $units/omarchy-update-user-notify.service ]] && ok "legacy unit omarchy-update-user-notify.service (drop-in installed)" || info "legacy unit omarchy-update-user-notify.service is gone (its drop-in is harmless)"
# ADR-0035 decision 10-1: Omarchy's pairing agent (bt-agent, NoInputNoOutput) is kept out of the session by name, so the
# bridge is bluetoothd's only agent there. Under another unit name it would run in both sessions and answer pairings.
if [[ -r $units/bt-agent.service ]]; then
  ok "user unit bt-agent.service exists (Grassfield's drop-in keeps Omarchy's pairing agent out of the session)"
elif grep -lq 'bin/bt-agent' "$units"/*.service 2>/dev/null; then
  bad "Omarchy's pairing agent runs under another unit name ($(grep -l 'bin/bt-agent' "$units"/*.service | xargs -n1 basename | tr '\n' ' ')): it would answer pairings in the Grassfield session"
else
  info "user unit bt-agent.service is gone (its drop-in is harmless)"
fi
for u in "$units"/omarchy-*.service; do
  [[ -e $u ]] || continue
  n=$(basename "$u" .service)
  case $n in
    omarchy-sleep-lock | omarchy-crash-watch | omarchy-migrate-notify | omarchy-update-user-notify) ;;
    *) if [[ -r $root/packaging/systemd/$n.service.d/10-grassfield.conf ]]; then :; else info "Omarchy unit $n.service has no Grassfield drop-in: it runs in both sessions (review: does it need the Omarchy shell?)"; fi ;;
  esac
done

# --- Login path (grassfield-login, SDDM) ------------------------------------------------------------------------------
have "Omarchy's own session file exists with a uwsm Exec line (grassfield-login starts it for 'omarchy')" bash -c 'grep -q "^Exec=uwsm" "$1/omarchy.desktop" || grep -q "^Exec=uwsm" /usr/share/wayland-sessions/hyprland-uwsm.desktop' _ "$sessions"
if [[ -r $theme ]]; then
  have "SDDM theme still picks the first session named *uwsm* (the 'Grassfield (uwsm)' entry relies on it) or offers a picker" \
    bash -c 'grep -q "indexOf(\"uwsm\")" "$1" || { grep -q sessionModel "$1" && grep -qi "ComboBox\|ListView" "$1"; }' _ "$theme"
else
  info "SDDM theme $theme not found (login heuristic not checked)"
fi

# --- Lock screen PAM service ------------------------------------------------------------------------------------------
have "shell/security/lock/Lock.qml still names the PAM service omarchy-lock-password" has_grep '"omarchy-lock-password"' "$root/shell/security/lock/Lock.qml"
if [[ -r $pam/omarchy-lock-password ]]; then
  ok "PAM service /etc/pam.d/omarchy-lock-password exists"
else
  have "PAM service omarchy-lock-password is missing but its generator omarchy-apply-lock exists (run it: the lock refuses without it)" test -x "$omarchy/bin/omarchy-apply-lock"
fi
have "omarchy-apply-lock still writes the service named omarchy-lock-password" has_grep 'omarchy-lock-password' "$omarchy/bin/omarchy-apply-lock"

# --- Hyprland Lua API used by config/hypr/grassfield -------------------------------------------------------------------
if [[ -r $stubs ]]; then
  for fn in bind on dispatch timer exec_cmd send_key_state get_active_window get_layers monitor env config gesture; do
    have "Hyprland Lua API hl.$fn (stub $stubs)" bash -c 'grep -q "\b$1\b" "$2"' _ "$fn" "$stubs"
  done
else
  info "Hyprland Lua stubs $stubs not found (API names not checked)"
fi

# --- Versions (information only; docs/compat.md records the last verified set) ---------------------------------------
if command -v pacman >/dev/null; then
  for p in omarchy omarchy-settings hyprland quickshell qt6-base uwsm sddm; do
    v=$(pacman -Q "$p" 2>/dev/null) && info "$v" || info "$p: not installed"
  done
fi

if ((fails)); then
  echo "omarchy-compat: $fails dependency check(s) FAILED: update docs/compat.md and the Grassfield code that relies on them"
  exit 1
fi
echo "omarchy-compat: all Omarchy dependencies present"
