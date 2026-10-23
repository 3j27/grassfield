#!/usr/bin/env bash
# The video layer of the wallpaper (shell/desktop/WallpaperVideo.qml) on the offscreen platform with a real clip: it starts when the
# policy says play, pauses for pause, eases down and pauses for settle, and resumes after each of them (ADR-0016 W7). The policy
# inputs themselves (battery, idle, ...) are WallpaperConfig.playbackState, tested in tst_wallpaper; the nested run
# (tests/visual/wallpaper-video.sh) covers them in a real compositor.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg is not installed"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wpplayer.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/home" "$tmp/config"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=40" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$tmp/clip.mp4"
ffmpeg -loglevel error -y -i "$tmp/clip.mp4" -frames:v 1 "$tmp/poster.jpg"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME GRASSFIELD_SESSION=1 \
  GRASSFIELD_TEST_CLIP="$tmp/clip.mp4" GRASSFIELD_TEST_POSTER="$tmp/poster.jpg" GRASSFIELD_STATE_HOME="$tmp/state" QT_QPA_PLATFORM=offscreen \
  QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" XDG_CONFIG_HOME="$tmp/config" \
  XDG_STATE_HOME="$tmp/state" HOME="$tmp/home" \
  /usr/bin/timeout 180 "$qs" -p "$root/tests/shell/wallpaper_video/player.qml" --no-color 2>&1) || { echo "$out" | tail -30; echo "FAIL: wallpaper_video_player (qs exit)"; exit 1; }
grep -E "wallpaper-video-player" <<<"$out" || true
grep -q "wallpaper-video-player: PASS" <<<"$out"
