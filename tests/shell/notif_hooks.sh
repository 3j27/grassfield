#!/usr/bin/env bash
# Test-only notification hooks (IPC invoke, clearAll, dismissAll) follow the VisualFixtures gate: they work only with
# GRASSFIELD_DEV=1 AND GRASSFIELD_VISUAL_FIXTURES=1 AND no GRASSFIELD_SESSION=1, and are refused otherwise. Runs the
# notif_clear test (real Notifications singleton, offscreen, no D-Bus server) in three environments:
#   allowed  dev + fixtures            -> hooks work
#   refused  dev, no fixtures          -> hooks refused, history untouched
#   refused  dev + fixtures + session  -> hooks refused (a packaged session turns every hook off)
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
tmp=$(mktemp -d "$root/.dev/notif-hooks.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/notif-hooks.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/config"
chmod 700 "$tmp/runtime" "$tmp/cache"
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null

run() { # mode extra-env... -> prints the test line, returns the test status
  local mode=$1
  shift
  rm -rf "$tmp/state"/* "$tmp/config"/*
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u GRASSFIELD_VISUAL_FIXTURES \
    GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" NOTIF_CLEAR_HOOKS="$mode" "$@" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" GRASSFIELD_LANG=en \
    XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" timeout 60 qs -p tests/shell/notif_clear --no-color 2>&1 | grep -E "PASS|FAIL"
}

fail=0
check() { # label mode env...
  local label=$1 out
  shift
  out=$(run "$@") || out="$out (qs failed)"
  if [[ $out == *"notif-clear: PASS"* ]]; then
    echo "PASS: notif hooks $label"
  else
    echo "FAIL: notif hooks $label: $out"
    fail=1
  fi
}

check "allowed with dev and fixtures" allowed GRASSFIELD_VISUAL_FIXTURES=1
check "refused without the fixtures flag" refused
check "refused in a packaged session" refused GRASSFIELD_VISUAL_FIXTURES=1 GRASSFIELD_SESSION=1
exit $fail
