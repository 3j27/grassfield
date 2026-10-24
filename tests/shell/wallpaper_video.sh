#!/usr/bin/env bash
# Video wallpaper state (ADR-0016 W7), headless: the crash marker (found at start -> blocked, no retry; written before a video
# starts; cleared), the lock still and the video cache kept by the pruning; plus static rules of the shell sources: a wallpaper
# never creates an idle inhibitor, the video layer has no audio output, the player loops and keeps its last frame, and the
# pause policy takes the five inputs of the ADR.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

# --- static ---
fail=0
code() { sed 's#//.*##' "$@"; }
if code shell/desktop/Wallpaper*.qml | grep -qE "IdleInhibitor|Inhibitor[[:space:]]*\{"; then echo "FAIL: a wallpaper file creates an idle inhibitor"; fail=1; fi
grep -q "respectInhibitors: false" shell/desktop/Wallpaper.qml || { echo "FAIL: the wallpaper's idle monitor must ignore inhibitors"; fail=1; }
if code shell/desktop/WallpaperVideo.qml | grep -qE "AudioOutput|audioOutput"; then echo "FAIL: the video layer must have no audio output"; fail=1; fi
grep -q "loops: MediaPlayer.Infinite" shell/desktop/WallpaperVideo.qml || { echo "FAIL: the video must loop"; fail=1; }
grep -q "endOfStreamPolicy: VideoOutput.KeepLastFrame" shell/desktop/WallpaperVideo.qml || { echo "FAIL: the video must keep its last frame"; fail=1; }
for input in "root.locked" "fullscreen" "idle" "onBattery" "Settings.reduceMotion" "Settings.materialProfile"; do
  grep -q "$input" shell/desktop/Wallpaper.qml || { echo "FAIL: pause policy input $input missing"; fail=1; }
done
((fail == 0)) || exit 1

# --- headless: WallpaperState with a crash marker in the state folder ---
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wpvideo.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/home" "$tmp/config"
printf '{"displays":{},"videoStarting":{"path":"/v/crash.mp4","at":1}}\n' >"$tmp/state/wallpaper.json"
qs=$(command -v qs)
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME GRASSFIELD_SESSION=1 \
  GRASSFIELD_STATE_HOME="$tmp/state" QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" \
  XDG_CACHE_HOME="$tmp/cache" XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state" HOME="$tmp/home" \
  /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/wallpaper_video/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: wallpaper_video (qs exit)"; exit 1; }
grep -E "wallpaper-video|wallpaper:" <<<"$out" || true
echo "state file at the end: $(cat "$tmp/state/wallpaper.json" 2>&1)"
grep -q "wallpaper-video: PASS" <<<"$out"
