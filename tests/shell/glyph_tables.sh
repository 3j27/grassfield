#!/usr/bin/env bash
# The class tables of the folder symbol rule are what the generator produces from the Unicode properties of ICU
# (scripts/dev/gen-glyph-tables.sh: ui/Grassfield/Ui/GraphemeData.js and apps/files/src/graphemedata.inc), and Files' rule
# agrees with ICU's own grapheme segmenter on random sequences (scripts/dev/glyph-icu-compare.sh). Both skip, with a
# SKIP line, where ICU's development files are not installed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if out=$("$root/scripts/dev/gen-glyph-tables.sh" --check 2>&1); then
  echo "PASS: glyph tables ($out)"
else
  echo "$out"
  echo "FAIL: the glyph tables are stale (run scripts/dev/gen-glyph-tables.sh)"
  exit 1
fi
if out=$("$root/scripts/dev/glyph-icu-compare.sh" 20000 1 2>&1); then
  echo "PASS: glyph rule vs ICU ($(tail -n 1 <<<"$out"))"
else
  echo "$out"
  echo "FAIL: the folder symbol rule differs from ICU's grapheme segmenter"
  exit 1
fi
