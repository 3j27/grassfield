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
# Omarchy 4.0.6 sets compose:caps; 4.5.0 sets its own XKB option omarchy:shift_caps_compose (Caps Lock stays Caps Lock, Shift + Caps
# Lock composes; defined in /etc/xkb, which omarchy.lua's fallback checks for). Either keeps the keyboard defaults Grassfield follows.
have "input.lua still reads the layout from /etc/vconsole.conf (XKBLAYOUT; 4.5.0 through default/hypr/keyboard.lua) and sets compose:caps or omarchy:shift_caps_compose" \
  bash -c 'grep -q XKBLAYOUT "$1" && grep -q "compose:caps\|omarchy:shift_caps_compose" "$1"' _ "$omarchy/default/hypr/input.lua"
# What input.lua requires (4.5.0: default.hypr.keyboard) must exist, or omarchy.lua's include falls back to its own defaults.
for req in $(sed -n 's/^[^-]*require("default\.hypr\.\([a-z_]*\)").*/\1/p' "$omarchy/default/hypr/input.lua" 2>/dev/null); do
  have "default/hypr/$req.lua (required by input.lua)" test -r "$omarchy/default/hypr/$req.lua"
done
have "envs.lua still sets OMARCHY_PATH and the Wayland environment the shell and apps expect" bash -c 'grep -q OMARCHY_PATH "$1" && grep -q QT_QPA_PLATFORM "$1"' _ "$omarchy/default/hypr/envs.lua"

# --- Commands Grassfield runs or shadows ------------------------------------------------------------------------------
for c in omarchy-restart-shell omarchy-launch-shell; do
  have "$c exists (Grassfield shadows it with a stand-in, packaging/shims)" test -x "$omarchy/bin/$c"
done
have "omarchy-update-restart still restarts the shell by the name omarchy-restart-shell (the stand-in is in the update's path)" has_grep omarchy-restart-shell "$omarchy/bin/omarchy-update-restart"
# A line that only greps for the string (4.5.0's omarchy-debug-idle lists processes) starts nothing: lines with grep, and comments, do not count.
have "omarchy-launch-shell is still the only command that starts the Omarchy shell (quickshell -n -p)" bash -c 'n=0; for f in "$1"/bin/*; do [[ -f $f ]] && grep -v "^[[:space:]]*#" "$f" 2>/dev/null | grep -v "grep" | grep -q "quickshell -n -p" && n=$((n + 1)); done; [[ $n == 1 ]] && grep -q "quickshell -n -p" "$1/bin/omarchy-launch-shell"' _ "$omarchy"
# Screenshots are Grassfield's own since ADR-0035 step 8 (packaging/bin/grassfield-capture): Omarchy's capture commands are no
# longer used.
for c in omarchy-hook omarchy-powerprofiles-init omarchy-powerprofiles-set omarchy-migrate omarchy-launch-floating-terminal-with-presentation omarchy-migrate-notify; do
  have "command $c exists (used by hooks, power profile, migration notice)" test -x "$omarchy/bin/$c"
done
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

# --- Omarchy capabilities used by the session (ADR-0045; docs/compat.md rows) -------------------------------------------
# Every one degrades gracefully when missing, but a rename or a changed contract would silently switch a feature off: fail.
for c in omarchy-menu-emoji-insert omarchy-brightness-display-ddc omarchy-theme-set omarchy-theme-current omarchy-theme-list omarchy-menu-share omarchy-weather-location; do
  have "command $c exists (ADR-0045: Emoji & Symbols, DDC brightness, terminal themes, LocalSend, Weather)" test -x "$omarchy/bin/$c"
done
emojis=$omarchy/shell/plugins/emojis/emojis.json
have "Emoji list $emojis is a JSON array of {e, k} whose group-first glyphs come in Unicode order (Emoji & Symbols' categories)" \
  python3 -I -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
glyphs = [d.get("e") for d in data if isinstance(d, dict)]
firsts = ["\U0001F600", "\U0001F44B", "\U0001F435", "\U0001F347", "\U0001F30D", "\U0001F383", "\U0001F453", "\U0001F3E7", "\U0001F3C1"]
at = [glyphs.index(g) if g in glyphs else -1 for g in firsts]
sys.exit(0 if isinstance(data, list) and all(isinstance(d.get("k"), str) for d in data) and at[0] == 0 and at == sorted(at) and -1 not in at else 1)' "$emojis"
have "omarchy-menu-emoji-insert still copies with wl-copy --sensitive and pastes with Shift+Insert" bash -c 'grep -q "wl-copy.*--sensitive" "$1" && grep -q "shift -k Insert" "$1"' _ "$omarchy/bin/omarchy-menu-emoji-insert"
have "omarchy-brightness-display-ddc still takes <monitor> [+N%|N%-|N%] (Brightness.qml, Settings > Displays)" has_grep '<monitor> \[+N%|N%-|N%\]' "$omarchy/bin/omarchy-brightness-display-ddc"
for th in catppuccin-latte tokyo-night; do
  have "theme $th exists (a default of terminal.lightTheme/darkTheme)" test -d "$omarchy/themes/$th"
done
# Omarchy's monitor watcher is not run in the Grassfield session; shell/platform/Displays.qml copies its "display on without a
# mode" rule (DisplaysFile.modeless) and recovers the same way (a reload with a back-off). A change of the rule is read and ported.
if [[ -e $omarchy/bin/omarchy-hyprland-monitor-modeless ]]; then
  have "omarchy-hyprland-monitor-modeless still decides 'enabled at 0x0' (DisplaysFile.modeless copies it)" has_grep '.disabled != true and (.width == 0 or .height == 0)' "$omarchy/bin/omarchy-hyprland-monitor-modeless"
else
  info "omarchy-hyprland-monitor-modeless not found (this Omarchy has no modeless recovery of its own to compare with)"
fi
have "omarchy-restart-hyprctl still reloads through hyprctl by name (grassfield-terminal-theme's private stand-in catches it)" has_grep '^hyprctl.* reload' "$omarchy/bin/omarchy-restart-hyprctl"
have "omarchy-theme-set-browser-policy still reaches pkexec by name (grassfield-terminal-theme's private stand-in refuses it)" has_grep 'exec pkexec ' "$omarchy/bin/omarchy-theme-set-browser-policy"
have "omarchy-theme-set calls no omarchy-restart-shell, qs, quickshell or systemctl (nothing may restart grassfield-shell)" \
  bash -c '! grep -Eq "(^|[^-[:alnum:]])(omarchy-restart-shell|qs|quickshell|systemctl)( |$)" "$1"' _ "$omarchy/bin/omarchy-theme-set"
have "omarchy-menu-share still sends with 'localsend --headless send' (Files: Send with LocalSend…)" has_grep 'localsend --headless send' "$omarchy/bin/omarchy-menu-share"
have "omarchy-weather-location still has --set and --clear and the file settings/weather.json (the Weather widget)" \
  bash -c 'grep -q -- "--set)" "$1" && grep -q -- "--clear)" "$1" && grep -q "settings/weather.json" "$1"' _ "$omarchy/bin/omarchy-weather-location"
for f in battlenet davinci-resolve geforce moonlight retroarch steam telegram pip webcam-overlay; do
  have "app rules default/hypr/apps/$f.lua exist (config/hypr/grassfield/apps.lua ports them)" test -r "$omarchy/default/hypr/apps/$f.lua"
done
# Settings' setups (ADR-0045 OC-0.4, OC-5 to OC-10): the exact commands of systemguard.cpp's launch allowlist and read-only checks.
for c in omarchy-setup-security-fingerprint omarchy-remove-security-fingerprint omarchy-setup-security-fido2 omarchy-remove-security-fido2 omarchy-setup-security-sshd omarchy-drive-password omarchy-hibernation-setup omarchy-hibernation-remove omarchy-hibernation-available omarchy-voxtype-model omarchy-hw-fingerprint omarchy-network-qr; do
  have "command $c exists (Settings: Fingerprint & Security Key, Sharing, Disk Encryption, Hibernation, Dictation, Share Network)" test -x "$omarchy/bin/$c"
done
# Dictation's setup pair was renamed in Omarchy 4.5 (omarchy-voxtype-install/-remove became omarchy-install/remove-dictation-voxtype);
# Settings launches whichever pair exists (apps/settings/qml/Setups.js, systemguard.cpp).
have "a dictation setup pair exists (4.0.6 omarchy-voxtype-install/-remove, or 4.5 omarchy-install/remove-dictation-voxtype)" \
  bash -c '{ test -x "$1/bin/omarchy-voxtype-install" && test -x "$1/bin/omarchy-voxtype-remove"; } ||
    { test -x "$1/bin/omarchy-install-dictation-voxtype" && test -x "$1/bin/omarchy-remove-dictation-voxtype"; }' _ "$omarchy"
have "omarchy-setup-security-sshd still writes the hardening file Settings reads (10-omarchy-hardening.conf)" has_grep '10-omarchy-hardening.conf' "$omarchy/bin/omarchy-setup-security-sshd"
have "omarchy-network-qr still has --meta (Share Network reads its meta line and matrix)" has_grep '--meta' "$omarchy/bin/omarchy-network-qr"
for pkg in gpu-screen-recorder tesseract zbarimg ddcutil localsend wtype wl-copy curl; do
  command -v "$pkg" >/dev/null 2>&1 && info "$pkg installed (ADR-0045)" || info "$pkg not installed: the ADR-0045 feature that uses it is hidden"
done

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
