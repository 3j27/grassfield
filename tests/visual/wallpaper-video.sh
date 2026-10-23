#!/usr/bin/env bash
# Video wallpaper end to end in the nested session (ADR-0016 W7): the transcode, playback, every pause input of the policy
# (battery, idle, Reduce Motion, lock), "paused = no decode" (the frame stops changing, the shell's CPU drops), play on battery,
# the idle lock firing while a video plays (the wallpaper never inhibits idle) and the crash marker (kill -9 while the video
# starts: the next shell shows the poster and does not play).
# The clip is generated under .dev/wallpapers-e2e (ffmpeg testsrc2 with an audio track, so that the transcode must drop it).
# Visual and timing checks need the nested compositor: NOT verified in the sandbox. Frame advance is read from two captures.
# Usage (bare command): tests/visual/wallpaper-video.sh        Captures: $VS_SHOTS/wallpaper-video-*.en.png
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics"
clip=$pics/clip.mp4
[[ -f $clip ]] || {
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=20" -f lavfi -i "sine=duration=20" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$clip"
}

fail=0
check() { # name command...
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

vs_session
vs_reset
cfg=$VS_DEV/config/grassfield.json
state=$VS_DEV/state/wallpaper.json
status=$VS_DEV/config/wallpaper-state.json
cache=$VS_DEV/cache/wallpapers/video

setcfg() { # jq filter over grassfield.json (the shell follows the file)
  jq "$1" "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
}
vstatus() { vs_ipc wallpaper videoStatus "$VS_OUTPUT"; }
field() { vstatus | jq -r ".$1"; }
# await SECONDS "shell expression" WANTED: polls the expression until its output is WANTED (evaluated again at every poll).
await() {
  local t=$1 expr=$2 want=$3 i
  for i in $(seq 1 $((t * 2))); do
    [[ $(eval "$expr" 2>/dev/null) == "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}
# fields a b c: the fields of the video status joined by "|".
fields() {
  local f out=""
  for f in "$@"; do out+="${out:+|}$(field "$f")"; done
  echo "$out"
}
# The shell reports ready on every output and one of them has a video.
ready_video() { echo "$(jq -r '[.outputs[] | .state] | unique | join(",")' "$status" 2>/dev/null)|$(jq -r '[.outputs[] | .video // ""] | map(select(. != "")) | length' "$status" 2>/dev/null)"; }
reasons() { jq -r '[.outputs[] | .reason] | unique | join(",")' "$status" 2>/dev/null; }
cpu_of() { # seconds: CPU percent of one core of the shell
  local pid t0 t1
  pid=$(dev_live_pid "$VS_DEV/shell.pid")
  t0=$(awk '{print $14+$15}' "/proc/$pid/stat")
  sleep "$1"
  t1=$(awk '{print $14+$15}' "/proc/$pid/stat")
  awk -v a="$t0" -v b="$t1" -v s="$1" 'BEGIN {printf "%.2f", (b-a)/100/s*100}'
}
# Two captures a moment apart: 0 when they are identical (a frozen frame), else the number of differing pixels.
frames_differ() {
  vs_capture wallpaper-video-a >/dev/null
  sleep 1
  vs_capture wallpaper-video-b >/dev/null
  magick compare -metric AE "$VS_SHOTS/wallpaper-video-a.$VS_LANG.png" "$VS_SHOTS/wallpaper-video-b.$VS_LANG.png" null: 2>&1 || true
}

# Play: Reduce Motion off (the visual contract turns it on), AC, not idle.
setcfg '.accessibility.reduceMotion = false | .wallpaper.source = "video" | .wallpaper.path = "'"$clip"'" | .wallpaper.videoOnBattery = false'
vs_ipc wallpaper videoBattery 0 >/dev/null
vs_ipc wallpaper videoIdle 0 >/dev/null
check "the shell reports ready with a video (transcode done)" await 120 ready_video "ready|1"
mp4=$(ls "$cache"/*.mp4 2>/dev/null | head -1)
check "a transcoded file exists in the video cache" test -n "$mp4"
codec=$(ffprobe -v error -show_entries stream=codec_name,pix_fmt,width,height,avg_frame_rate -of json "$mp4" 2>/dev/null)
check "H.264 yuv420p, no larger than the output, at most 30 fps" bash -c '
  echo "$1" | jq -e "(.streams | length == 1) and .streams[0].codec_name == \"h264\" and .streams[0].pix_fmt == \"yuv420p\" and .streams[0].width <= 1920 and .streams[0].height <= 1080 and ((.streams[0].avg_frame_rate | split(\"/\") | (.[0] | tonumber) / (.[1] | tonumber)) <= 30.5)" >/dev/null' _ "$codec"
check "the transcoded file has no audio" test -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$mp4")"
check "the cache folder is private (0700)" test "$(stat -c %a "$cache")" = 700
check "policy is play and a frame is decoding" await 20 "fields policy playing" "play|true"
sleep 2
check "the video advances (two captures differ)" test "$(frames_differ)" != 0
check "no QML error in the shell log" test "$(grep -cE 'ERROR|TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0

# Paused = no decode: battery power without "play on battery".
vs_ipc wallpaper videoBattery 1 >/dev/null
check "battery: policy pause (reason battery)" await 10 "fields policy reason" "pause|battery"
check "battery: the player is paused" await 10 "field playing" false
sleep 4
check "battery: the frame is frozen (two captures identical)" test "$(frames_differ)" = 0
paused_cpu=$(cpu_of 10)
echo "shell CPU while paused: $paused_cpu % of one core over 10 s"
check "battery: a paused video costs under 3 % of one core" awk -v p="$paused_cpu" 'BEGIN {exit !(p < 3.0)}'
setcfg '.wallpaper.videoOnBattery = true'
check "battery with play on battery: plays again" await 20 "fields policy playing" "play|true"
setcfg '.wallpaper.videoOnBattery = false'
vs_ipc wallpaper videoBattery 0 >/dev/null
check "AC: plays" await 20 "field playing" true

# Idle: the rate eases down (2 s) and the player pauses.
vs_ipc wallpaper videoIdle 1 >/dev/null
check "idle: policy settle" await 5 "field policy" settle
check "idle: paused after the easing" await 15 "field playing" false
vs_ipc wallpaper videoIdle 0 >/dev/null
check "not idle: plays again" await 20 "field playing" true

# Reduce Motion: pause at once.
setcfg '.accessibility.reduceMotion = true'
check "Reduce Motion: policy pause (reason reduce-motion), paused" await 10 "fields policy reason playing" "pause|reduce-motion|false"
setcfg '.accessibility.reduceMotion = false'
check "Reduce Motion off: plays" await 20 "field playing" true

# The wallpaper never inhibits idle: with a video playing and no input, the idle lock still fires (lock.idleMinutes 1: dim, then
# lock; the real compositor idle of the nested session, nobody touches the pointer or the keyboard meanwhile).
setcfg '.lock.idleMinutes = 1'
check "the video plays before the idle wait" test "$(field playing)" = true
idle_json=$(vs_ipc idle status 2>/dev/null || true)
echo "idle status while the video plays: $idle_json"
check "the idle monitor of the lock is enabled" test "$(jq -r .enabled <<<"$idle_json" 2>/dev/null)" = true
check "the idle lock fires while the video plays (within 3 minutes)" await 180 "vs_ipc lock status" locked
setcfg '.lock.idleMinutes = 0'

# Locked (by the idle lock above): the video pauses. Unlocking is the security tests' business; the crash-marker part below
# restarts the shell, which ends the lock of the nested session.
check "locked: policy pause (reason locked), paused" await 10 "fields policy reason playing" "pause|locked|false"

# Crash marker: a shell killed (SIGKILL) while the video starts leaves the marker; the next shell shows the poster, no playback.
vs_kill_clients
shellpid=$(dev_live_pid "$VS_DEV/shell.pid")
kill -9 "$shellpid" 2>/dev/null || true
sleep 1
# The marker is only left when the kill came inside the first 10 s of a playback: start one, then kill at once.
setcfg '.wallpaper.source = "builtin"'
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop" >/dev/null
for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
vs_ipc wallpaper videoBattery 0 >/dev/null
vs_ipc wallpaper videoIdle 0 >/dev/null
setcfg '.accessibility.reduceMotion = false | .wallpaper.source = "video" | .wallpaper.path = "'"$clip"'"'
await 60 "field playing" true || true
kill -9 "$(dev_live_pid "$VS_DEV/shell.pid")" 2>/dev/null || true
sleep 1
check "the crash marker is in wallpaper.json after the kill" test "$(jq -r '.videoStarting.path // ""' "$state")" = "$clip"
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop" >/dev/null
for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
vs_ipc wallpaper videoBattery 0 >/dev/null
vs_ipc wallpaper videoIdle 0 >/dev/null
check "the next shell reports the poster with the reason video-crashed" await 60 reasons video-crashed
sleep 3
check "the blocked video is not played" test "$(field playing)" = false
check "the marker is gone and the block is remembered" test "$(jq -r '(.videoStarting // "none") + "|" + (.videoBlocked // "")' "$state")" = "none|$clip"
vs_capture wallpaper-video-poster >/dev/null

vs_kill_clients
exit "$fail"
