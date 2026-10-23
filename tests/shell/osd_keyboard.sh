#!/usr/bin/env bash
# Keyboard backlight OSD (REQ-OSD-NG-d1a, docs/specs/osd.md requirement 8): runs tests/shell/osd_keyboard.d/guard.qml offscreen in a
# dev session (GRASSFIELD_DEV=1: nothing touches the hardware; no wpctl or brightnessctl is on PATH to be started) and prints
# PASS or FAIL. Plain shell test: exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
tmp=$(mktemp -d "$root/.dev/osd-keyboard.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/osd-keyboard.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/cfg" "$tmp/bin"
chmod 700 "$tmp/runtime" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/osd_keyboard.d/guard.qml "$tmp/cfg/shell.qml"
# Shims that only record a call: a backlight command must never run in this test.
for tool in brightnessctl wpctl pactl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/marker"\nexit 0\n' "$tool" "$tmp" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_DEV=1 PATH="$tmp/bin:$PATH" QT_QPA_PLATFORM=offscreen \
  QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  timeout 60 qs -p "$tmp/cfg" --no-color 2>&1 || true)
fail=0
echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; fail=1; }
grep -q FAIL <<<"$out" && fail=1
if [[ -e $tmp/marker ]] && grep -q brightnessctl "$tmp/marker"; then
  echo "FAIL: osd_keyboard brightnessctl ran in a dev session: $(cat "$tmp/marker")"
  fail=1
else
  echo "PASS: osd_keyboard no brightnessctl process started"
fi
exit $fail
