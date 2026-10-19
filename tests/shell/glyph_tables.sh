#!/usr/bin/env bash
# ui/Grassfield/Ui/GraphemeData.js is what FolderStyleLogic::glyphClasses generates (scripts/dev/gen-glyph-tables.sh):
# the QML and the C++ side of the folder symbol rule run one algorithm over one set of data.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if "$root/scripts/dev/gen-glyph-tables.sh" --check; then
  echo "PASS: GraphemeData.js is generated from FolderStyleLogic::glyphClasses"
else
  echo "FAIL: GraphemeData.js is stale (run scripts/dev/gen-glyph-tables.sh)"
  exit 1
fi
