#!/usr/bin/env bash
# Compile translations/*.ts to .qm. Dev: .dev/translations (GRASSFIELD_TRANSLATIONS_DIR points there);
# packaging builds the same catalogs into /usr/share/grassfield/translations (PKGBUILD / CMake).
# Usage: scripts/dev/i18n-build.sh [outdir]
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out=${1:-$root/.dev/translations}
mkdir -p "$out"
for ts in "$root"/translations/grassfield_*.ts; do
  qm=$out/$(basename "${ts%.ts}").qm
  if [[ -f $qm && $qm -nt $ts ]]; then continue; fi
  /usr/lib/qt6/bin/lrelease -silent "$ts" -qm "$qm"
  echo "i18n-build: $qm"
done
