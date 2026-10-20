#!/usr/bin/env bash
# Build the Qt shaders of ui/Grassfield/Ui/shaders (*.frag -> *.frag.qsb with qsb) and record the source hashes.
#
#   scripts/dev/build-shaders.sh           rebuild every .qsb (writes shaders/SOURCES.sha256)
#   scripts/dev/build-shaders.sh --check   exit 1 if a .frag changed since its .qsb was built (no build; used by `just check`)
#
# The .qsb files are committed (QML loads them from the installed module directory, there is no build step at install
# time), so a shader edit must be followed by this script. The check compares source hashes, not bytes: qsb output
# depends on the Qt version, the source does not.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dir=$root/ui/Grassfield/Ui/shaders
qsb=/usr/lib/qt6/bin/qsb
sums=$dir/SOURCES.sha256

current() { (cd "$dir" && sha256sum -- *.frag); }

if [[ ${1:-} == --check ]]; then
  [[ -f $sums ]] || { echo "build-shaders: $sums missing (run scripts/dev/build-shaders.sh)" >&2; exit 1; }
  for f in "$dir"/*.frag; do
    [[ -f $f.qsb ]] || { echo "build-shaders: ${f##*/}.qsb missing (run scripts/dev/build-shaders.sh)" >&2; exit 1; }
  done
  if ! diff <(current) "$sums" >/dev/null; then
    echo "build-shaders: a .frag changed since the .qsb was built (run scripts/dev/build-shaders.sh)" >&2
    exit 1
  fi
  # The hashes say the source is the one the .qsb was built from; a rebuild must also give the committed bytes (a .qsb edited or
  # built from other contents is caught). Only where qsb is present (the output of one qsb version is stable).
  if [[ -x $qsb ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    for f in "$dir"/*.frag; do
      "$qsb" --qt6 -o "$tmp/${f##*/}.qsb" "$f"
      cmp -s "$tmp/${f##*/}.qsb" "$f.qsb" || { echo "build-shaders: ${f##*/}.qsb is not what qsb builds from its source (rebuild: scripts/dev/build-shaders.sh)" >&2; exit 1; }
    done
  fi
  echo "build-shaders: up to date"
  exit 0
fi

for f in "$dir"/*.frag; do
  "$qsb" --qt6 -o "$f.qsb" "$f"
  echo "build-shaders: ${f##*/}.qsb"
done
current >"$sums"
