#!/usr/bin/env bash
# Regenerate ui/Grassfield/Ui/GraphemeData.js: the class of every code point for the folder symbol rule, taken from
# FolderStyleLogic::glyphClasses (apps/files/src/folderstylelogic.cpp, scripts/dev/glyph-tables.cpp) so Files (C++) and
# the shell (QML) run one algorithm over one set of data. Run it after changing the classes (or a Qt update that changes
# QChar::category); tests/fixtures/glyph-vectors.json (both test suites) tells whether the two sides agree.
# --check: fail when the file is not what the current source generates (the first line, which names the Qt version, is
# not compared).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out=$root/ui/Grassfield/Ui/GraphemeData.js
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset QT_QPA_PLATFORMTHEME
read -r -a flags < <(pkg-config --cflags --libs Qt6Core)
g++ -std=c++17 -fPIC -Wno-sfinae-incomplete -I"$root/apps/files/src" "$root/scripts/dev/glyph-tables.cpp" "$root/apps/files/src/folderstylelogic.cpp" -o "$tmp/gen" "${flags[@]}"
QT_QPA_PLATFORM=offscreen "$tmp/gen" | sed -E 's/[[:space:]]+$//' > "$tmp/GraphemeData.js"
if [[ ${1:-} == --check ]]; then
  diff <(tail -n +2 "$tmp/GraphemeData.js") <(tail -n +2 "$out") >/dev/null \
    || { echo "gen-glyph-tables: $out is not what the source generates; run scripts/dev/gen-glyph-tables.sh" >&2; exit 1; }
  echo "gen-glyph-tables: up to date"
else
  mv "$tmp/GraphemeData.js" "$out"
  echo "gen-glyph-tables: wrote $out"
fi
