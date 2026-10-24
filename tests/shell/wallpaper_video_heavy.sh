#!/usr/bin/env bash
# Heavy video wallpaper test (minutes, several GiB of RAM): 8K sources in H.264, HEVC 10-bit and AV1, 60 frames, transcoded to a 4K
# video under the real memory cap with forced high thread counts, plus their thumbnails (ADR-0016 W7).
# Not part of `just test`: scripts/dev/test.sh runs every tests/shell/*.sh, so without --run this script only says SKIP
# (generating the HEVC source alone takes about 50 s; under load the whole test took 446 s).
# Usage (bare command): tests/shell/wallpaper_video_heavy.sh --run
set -euo pipefail
if [[ ${1:-} != --run ]]; then
  echo "SKIP: heavy test, run it by hand with: tests/shell/wallpaper_video_heavy.sh --run"
  exit 0
fi
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
apps/wallpaper-tool/build-direct.sh --tests >/dev/null
GRASSFIELD_HEAVY_TESTS=1 QT_QPA_PLATFORM=offscreen exec .dev/build/wallpaper-unit-tests --gtest_filter='VideoToolHeavy*'
