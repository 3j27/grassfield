#!/usr/bin/env bash
# Compares the folder symbol rule of Files (FolderStyleLogic::normalizeGlyph, isEmoji) with ICU's own grapheme segmenter on
# random sequences (scripts/dev/glyph-icu-compare.cpp). Development tool: needs ICU's development files (pkg-config icu-uc),
# skips without them; nothing of the product links ICU.
#
#   scripts/dev/glyph-icu-compare.sh [N [SEED]]            compare (default 30000 sequences)
#   scripts/dev/glyph-icu-compare.sh vectors N SEED        print ICU's answers as JSON vectors
#   scripts/dev/glyph-icu-compare.sh ask                   ICU's answer for each line of hex code points on stdin
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! pkg-config --exists icu-uc; then
  echo "SKIP: glyph-icu-compare (ICU development files are not installed)"
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset QT_QPA_PLATFORMTHEME
read -r -a flags < <(pkg-config --cflags --libs Qt6Core icu-uc)
g++ -std=c++17 -fPIC -Wno-sfinae-incomplete -I"$root/apps/files/src" "$root/scripts/dev/glyph-icu-compare.cpp" "$root/apps/files/src/folderstylelogic.cpp" -o "$tmp/compare" "${flags[@]}"
if [[ ${1:-} == ask ]]; then
  QT_QPA_PLATFORM=offscreen "$tmp/compare" ask
elif [[ ${1:-} == vectors ]]; then
  QT_QPA_PLATFORM=offscreen "$tmp/compare" vectors "${2:-100}" "${3:-1}"
else
  QT_QPA_PLATFORM=offscreen "$tmp/compare" compare "${1:-30000}" "${2:-1}"
fi
