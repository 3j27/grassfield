#!/usr/bin/env bash
# Dev guard of the audio service: in a GRASSFIELD_DEV session NOTHING may change the owner's audio. Runs
# tests/shell/audio_dev_guard.d/shell.qml (every volume, mute, key and device action) offscreen with a wpctl shim first on PATH
# that only records its arguments, twice: dev (must make zero backend calls, zero wpctl runs) and a control without
# the guard (must write the stand-in sink and run the shim, which proves the test can fail). The shim is the only
# wpctl that can run here: nothing touches the machine.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
tmp=$(mktemp -d "$root/.dev/audio-guard.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/audio-guard.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runtime" "$tmp/cache"
chmod 700 "$tmp/runtime" "$tmp/cache"
# Config dir: the test shell.qml next to links to every module of the real shell (qs.services needs its siblings).
mkdir -p "$tmp/cfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/audio_dev_guard.d/shell.qml "$tmp/cfg/shell.qml"
for tool in wpctl pactl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/marker"\nexit 0\n' "$tool" "$tmp" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done

run() { # mode (dev|real) -> prints qs output
  rm -f "$tmp/marker"
  local envdev=()
  [[ $1 == dev ]] && envdev=(GRASSFIELD_DEV=1)
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV "${envdev[@]}" GF_EXPECT="$1" \
    PATH="$tmp/bin:$PATH" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
    XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
    timeout 60 qs -p "$tmp/cfg" --no-color 2>&1 || true
}

out=$(run dev)
echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; fail=1; }
grep -q FAIL <<<"$out" && fail=1
if [[ -e $tmp/marker ]]; then echo "FAIL: audio_dev_guard (dev) a mixer tool ran: $(cat "$tmp/marker")"; fail=1; else echo "PASS: audio_dev_guard (dev) no wpctl/pactl process started"; fi

out=$(run real)
echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; fail=1; }
grep -q FAIL <<<"$out" && fail=1
if grep -q "wpctl set-volume" "$tmp/marker" 2>/dev/null; then echo "PASS: audio_dev_guard (control) the shim recorded the key steps"; else echo "FAIL: audio_dev_guard (control) the shim never ran"; fail=1; fi
exit $fail
