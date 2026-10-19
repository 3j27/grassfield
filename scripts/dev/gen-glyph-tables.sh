#!/usr/bin/env bash
# Regenerate the class tables of the folder symbol rule from the Unicode properties of the installed ICU (generation
# time only; no product code links ICU):
#   ui/Grassfield/Ui/GraphemeData.js     read by FolderStyle.js (the shell)
#   apps/files/src/graphemedata.inc      included by folderstylelogic.cpp (Files)
# so both sides run one algorithm over one set of data. Run it after changing the classes in scripts/dev/glyph-tables.cpp
# or when the system's Unicode data changes; tests/fixtures/glyph-vectors.json (both test suites) and
# scripts/dev/glyph-icu-compare.sh (random sequences against ICU's own segmenter) tell whether they agree.
# --check: fail when a file is not what the generator produces now (the first line, which names the ICU version, is not
# compared); skipped (exit 0, "SKIP") when ICU's development files are not installed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
js=$root/ui/Grassfield/Ui/GraphemeData.js
inc=$root/apps/files/src/graphemedata.inc
if ! pkg-config --exists icu-uc; then
  if [[ ${1:-} == --check ]]; then
    echo "SKIP: gen-glyph-tables (ICU development files are not installed)"
    exit 0
  fi
  echo "gen-glyph-tables: ICU development files (pkg-config icu-uc) are needed" >&2
  exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
read -r -a flags < <(pkg-config --cflags --libs icu-uc)
g++ -std=c++17 "$root/scripts/dev/glyph-tables.cpp" -o "$tmp/gen" "${flags[@]}"
"$tmp/gen" js | sed -E 's/[[:space:]]+$//' > "$tmp/GraphemeData.js"
"$tmp/gen" cpp | sed -E 's/[[:space:]]+$//' > "$tmp/graphemedata.inc"
if [[ ${1:-} == --check ]]; then
  diff <(tail -n +2 "$tmp/GraphemeData.js") <(tail -n +2 "$js") >/dev/null \
    && diff <(tail -n +2 "$tmp/graphemedata.inc") <(tail -n +2 "$inc") >/dev/null \
    || { echo "gen-glyph-tables: the generated tables are stale; run scripts/dev/gen-glyph-tables.sh" >&2; exit 1; }
  echo "gen-glyph-tables: up to date"
else
  mv "$tmp/GraphemeData.js" "$js"
  mv "$tmp/graphemedata.inc" "$inc"
  echo "gen-glyph-tables: wrote $js and $inc"
fi
