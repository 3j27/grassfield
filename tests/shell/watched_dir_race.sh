#!/usr/bin/env bash
# WatchedDir: a path change while mkdir runs must not signal `ready` on the end of the old mkdir.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/watcheddir.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/bin" "$tmp/base"
# A slow mkdir keeps the first one running while the probe changes the path.
cat >"$tmp/bin/mkdir" <<'EOF'
#!/bin/bash
sleep 1
exec /usr/bin/mkdir "$@"
EOF
chmod +x "$tmp/bin/mkdir"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u QT_QPA_PLATFORMTHEME PATH="$tmp/bin:/usr/bin" GF_BASE="$tmp/base" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/watched_dir_race/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: watched_dir_race (qs exit)"; exit 1; }
grep "watched-dir" <<<"$out" || true
grep -q "watched-dir: PASS" <<<"$out"
