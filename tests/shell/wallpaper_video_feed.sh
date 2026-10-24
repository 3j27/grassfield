#!/usr/bin/env bash
# The block of a crashed video is for the automatic restart only: a change of wallpaper after the shell started (away from the video,
# or to it) lifts it, an unrelated setting does not (ADR-0016 section 5; the real WallpaperFeed, headless). Regression of the nested
# run where choosing the video again still showed "stopped; not played again".
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wpfeed.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/home" "$tmp/config" "$tmp/configs"
printf '{"displays":{},"videoStarting":{"path":"/v/crash.mp4","at":1}}\n' >"$tmp/state/wallpaper.json"
cfg() { # name wallpaper-json
  printf '{"version":1,"wallpaper":%s}\n' "$2" >"$tmp/configs/$1.json"
}
cfg crash-video '{"source":"video","path":"/v/crash.mp4"}'
cfg same-video-fit '{"source":"video","path":"/v/crash.mp4","fit":"fit"}'
cfg builtin '{"source":"builtin"}'
cfg other-video '{"source":"video","path":"/v/other.mp4"}'
cp "$tmp/configs/crash-video.json" "$tmp/config/grassfield.json"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME GRASSFIELD_SESSION=1 \
  GRASSFIELD_CONFIG_HOME="$tmp/config" GRASSFIELD_TEST_CONFIGS="$tmp/configs" GRASSFIELD_STATE_HOME="$tmp/state" QT_QPA_PLATFORM=offscreen \
  QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" XDG_CONFIG_HOME="$tmp/home" \
  XDG_STATE_HOME="$tmp/state" HOME="$tmp/home" \
  /usr/bin/timeout 90 "$qs" -p "$root/tests/shell/wallpaper_video_feed/probe.qml" --no-color 2>&1) || { echo "$out" | tail -25; echo "FAIL: wallpaper_video_feed (qs exit)"; exit 1; }
grep -E "wallpaper-video-feed" <<<"$out" || true
grep -q "wallpaper-video-feed: PASS" <<<"$out"
