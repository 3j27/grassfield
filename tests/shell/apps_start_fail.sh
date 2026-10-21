#!/usr/bin/env bash
# Apps.qml releases the queue of launches when the uwsm-app probe (`sh`) cannot start (no `exited` is sent then).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/appsfail.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME PATH=/nonexistent GRASSFIELD_SESSION=1 \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/apps_start_fail/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: apps_start_fail (qs exit)"; exit 1; }
grep -E "apps-start-fail|could not start sh" <<<"$out" || true
grep -q "apps-start-fail: PASS" <<<"$out"
