#!/usr/bin/env bash
# WallpaperOnline leaves "scheduled" and "fetching" when nmcli or the helper cannot start (no `exited` is sent then) and kills
# a hanging nmcli or helper after its timeout. Headless: the real service on the offscreen platform.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wponfail.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/home"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME PATH=/nonexistent GRASSFIELD_SESSION=1 \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  XDG_STATE_HOME="$tmp/state" HOME="$tmp/home" \
  /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/wallpaper_online_start_fail/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: wallpaper_online_start_fail (qs exit)"; exit 1; }
grep -E "wallpaper-online-start-fail|wallpaper online" <<<"$out" || true
grep -q "wallpaper-online-start-fail: PASS" <<<"$out"
