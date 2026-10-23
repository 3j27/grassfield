#!/usr/bin/env bash
# Heavy video wallpaper test (minutes): 8K sources in H.264, HEVC 10-bit and AV1, 60 frames, transcoded to a 4K video under
# the real memory cap with forced high thread counts, plus their thumbnails (ADR-0016 W7).
# Not part of `just test` (generating the HEVC source alone takes about 50 s).
# Usage (bare command): tests/shell/wallpaper_video_heavy.sh
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
apps/wallpaper-tool/build-direct.sh --tests >/dev/null
GRASSFIELD_HEAVY_TESTS=1 QT_QPA_PLATFORM=offscreen exec .dev/build/wallpaper-unit-tests --gtest_filter='VideoToolHeavy*'
