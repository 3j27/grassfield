#!/usr/bin/env bash
# grassfield-wallpaper and SIGTERM (ADR-0016): the shell cancels a superseded job with SIGTERM (WallpaperFeed.supersede), so
#   - `prepare`, `list`, a still `thumb` and `fetch` must die at once (default action: no handler may swallow the signal);
#   - `transcode` and `probe` end as "cancelled" (exit 17) and take their ffmpeg with them;
#   - a path that is not a video file name is refused by `probe` and `transcode` before anything runs.
# Regression of the first review of the video work: a handler installed for every subcommand made `prepare` ignore SIGTERM.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
apps/wallpaper-tool/build-direct.sh >/dev/null
helper=$root/.dev/build/grassfield-wallpaper
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg is not installed"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wptool.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# A 62 MP PNG: the decode takes over a second.
big=$tmp/big.png
ffmpeg -loglevel error -y -f lavfi -i "gradients=s=7900x7900:seed=3:n=4:speed=0" -frames:v 1 "$big"
mkdir -p "$tmp/cache/wallpapers"

# term_after SECONDS_TO_WAIT command...: starts the command, sends SIGTERM after the wait; prints "<exit code> <elapsed ms>".
term_after() {
  local wait=$1 t0 t1 pid rc
  shift
  t0=$(date +%s%N)
  "$@" >/dev/null 2>&1 &
  pid=$!
  sleep "$wait"
  kill -TERM "$pid" 2>/dev/null || true
  rc=0
  wait "$pid" || rc=$?
  t1=$(date +%s%N)
  echo "$rc $(((t1 - t0) / 1000000))"
}

# prepare: killed by the signal (143), quickly, and no picture written.
out=$(term_after 0.15 "$helper" prepare --size 1920x1080 --fit fill --color '#000000' --out "$tmp/cache/wallpapers/prepared" -- "$big")
read -r rc ms <<<"$out"
echo "prepare: exit $rc after $ms ms"
check "prepare dies on SIGTERM (143)" test "$rc" = 143
check "prepare dies promptly (under 1 s)" test "$ms" -lt 1000
check "no prepared picture was written" test -z "$(ls "$tmp/cache/wallpapers/prepared"/*.jpg 2>/dev/null)"

# fetch against a loopback server that never answers: curl is running when the signal comes. The helper dies at once and curl
# dies with it (parent-death signal), not after its 60 s --max-time.
python3 -I "$root/tests/unit/wallpaper-tool/fixtures/slow_server.py" "$tmp/port" &
slow=$!
trap 'kill "$slow" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 50); do [[ -s $tmp/port ]] && break; sleep 0.1; done
port=$(<"$tmp/port")
out=$(term_after 1 env GRASSFIELD_DEV=1 "$helper" fetch commons --date 2026-10-20 --out "$tmp/cache/wallpapers/online/commons" --base-url "http://127.0.0.1:$port")
read -r rc ms <<<"$out"
echo "fetch: exit $rc after $ms ms (server on port $port)"
check "fetch dies on SIGTERM (143) while curl waits for the server" test "$rc" = 143
check "fetch dies promptly (under 2 s)" test "$ms" -lt 2000
sleep 0.5
check "no curl of that fetch is left" test -z "$(pgrep -f "curl.*127.0.0.1:$port" || true)"
kill "$slow" 2>/dev/null || true

# A clip long enough to be encoding when the signal comes.
clip=$tmp/clip.mp4
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=120" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$clip"
mkdir -p "$tmp/cache/wallpapers"
out=$(term_after 2 "$helper" transcode --size 1920x1080 --fit fill --color '#000000' --out "$tmp/cache/wallpapers/video" -- "$clip")
read -r rc ms <<<"$out"
echo "transcode: exit $rc after $ms ms"
check "transcode ends as cancelled (17)" test "$rc" = 17
check "transcode stops within 3 s of the signal" test "$ms" -lt 5000
check "no ffmpeg of that run is left" test -z "$(pgrep -f "$clip" || true)"
check "no temporary file is left" test -z "$(ls -A "$tmp/cache/wallpapers/video"/.vt-* 2>/dev/null || true)"

# Names that are not videos never reach ffmpeg.
printf 'not a video\n' >"$tmp/list.m3u8"
for sub in probe transcode; do
  if [[ $sub == probe ]]; then
    json=$("$helper" probe -- "$tmp/list.m3u8" || true)
  else
    json=$("$helper" transcode --size 640x360 --fit fill --color '#000000' --out "$tmp/cache/wallpapers/video" -- "$tmp/list.m3u8" || true)
  fi
  check "$sub refuses a playlist name (code 8)" test "$(jq -r .code <<<"$json")" = 8
done

exit "$fail"
