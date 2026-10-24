#!/usr/bin/env bash
# Licence notices and metadata (GF-014, ARCH-12), offline. Fails when:
#   - packaging/licenses/omarchy-MIT.txt does not carry Omarchy's LICENSE verbatim: the text from its copyright line to the
#     end must hash to the pinned SHA-256 of basecamp/omarchy v4.0.4's LICENSE and name "David Heinemeier Hansson"
#   - a package_*() function of packaging/arch/PKGBUILD lacks a licence it ships: grassfield-desktop MIT + CC-BY-SA-4.0 +
#     Unicode-3.0, grassfield-compositor MIT + LGPL-2.1-or-later + BSD-3-Clause, grassfield-icons MIT + GPL-3.0-only
#   - a file of packaging/licenses/ is not installed by the PKGBUILD or not named in THIRD_PARTY.md
#   - the notices that must ship are missing (LICENSE, THIRD_PARTY.md, Unicode License v3, the appmenu LGPL text)
#   - THIRD_PARTY.md still says the project licence is unsettled or the Omarchy holder is "the Omarchy authors"
# `scripts/dev/check-licenses.sh --selftest` runs the pieces on temporary files. Exit 0 ok, 1 not.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
omarchy_sha=717ba1949502290f8e47688ae2e323acd06c8ca47aec9f7596b15f678c1af4a2
marker='Copyright (c) David Heinemeier Hansson'

block_sha() { # <notice file>: SHA-256 of the text from the copyright line to the end
  sed -n "/^$marker\$/,\$p" "$1" | sha256sum | cut -d' ' -f1
}
licenses_of() { # <PKGBUILD> <package>: the license= array of package_<package>()
  awk -v fn="package_$2" '
    $0 ~ "^" fn "\\(\\)" { infn = 1; next }
    infn && /^}/ { infn = 0 }
    infn && /^ *license=\(/ { gsub(/^ *license=\(|\).*$/, ""); print; exit }' "$1"
}
need() { # <PKGBUILD> <package> <licence...>: prints the missing ones
  local have w
  have=" $(licenses_of "$1" "$2") "
  shift 2
  for w in "$@"; do [[ $have == *" $w "* ]] || echo "$w"; done
}

check_tree() { # <root>
  local t=$1 n=0 missing f sha
  if [[ -f $t/packaging/licenses/omarchy-MIT.txt ]]; then
    sha=$(block_sha "$t/packaging/licenses/omarchy-MIT.txt")
    [[ $sha == "$omarchy_sha" ]] || { echo "omarchy-MIT.txt: the block after the marker is not Omarchy's LICENSE verbatim (sha256 $sha)"; n=$((n + 1)); }
    grep -q '^Copyright (c) David Heinemeier Hansson$' "$t/packaging/licenses/omarchy-MIT.txt" || { echo "omarchy-MIT.txt: the copyright holder is not David Heinemeier Hansson"; n=$((n + 1)); }
  else
    echo "packaging/licenses/omarchy-MIT.txt: missing"; n=$((n + 1))
  fi
  for spec in "grassfield-desktop:MIT CC-BY-SA-4.0 Unicode-3.0" "grassfield-compositor:MIT LGPL-2.1-or-later BSD-3-Clause" "grassfield-icons:MIT GPL-3.0-only"; do
    # shellcheck disable=SC2086
    missing=$(need "$t/packaging/arch/PKGBUILD" "${spec%%:*}" ${spec#*:} | paste -sd' ' -)
    [[ -z $missing ]] || { echo "PKGBUILD: ${spec%%:*} license= lacks: $missing"; n=$((n + 1)); }
  done
  for f in "$t"/packaging/licenses/*; do
    [[ -f $f ]] || continue
    grep -q "$(basename "$f")" "$t/packaging/arch/PKGBUILD" || { echo "packaging/licenses/$(basename "$f"): not installed by the PKGBUILD"; n=$((n + 1)); }
    grep -q "$(basename "$f")" "$t/THIRD_PARTY.md" || { echo "packaging/licenses/$(basename "$f"): not named in THIRD_PARTY.md"; n=$((n + 1)); }
  done
  for f in LICENSE THIRD_PARTY.md packaging/licenses/unicode-license-v3.txt packaging/licenses/appmenu-LGPL-2.1-or-later.txt packaging/licenses/hyprland-BSD-3-Clause.txt; do
    [[ -s $t/$f ]] || { echo "$f: missing or empty"; n=$((n + 1)); }
  done
  grep -q 'Unicode-3.0' "$t/packaging/licenses/unicode-license-v3.txt" 2>/dev/null || { echo "unicode-license-v3.txt: no SPDX line"; n=$((n + 1)); }
  if grep -q -E 'licence is not settled|no root `LICENSE` yet' "$t/THIRD_PARTY.md" 2>/dev/null; then echo "THIRD_PARTY.md: still says the project licence is unsettled"; n=$((n + 1)); fi
  if grep -q 'Copyright (c) the Omarchy authors$' "$t/packaging/licenses/omarchy-MIT.txt" 2>/dev/null; then echo "omarchy-MIT.txt: still names 'the Omarchy authors' as holder"; n=$((n + 1)); fi
  ((n == 0))
}

selftest() {
  local d fails=0
  d=$(mktemp -d)
  trap 'rm -rf "$d"' RETURN
  printf 'preamble\n%s\n\nbody\n' "$marker" >"$d/n.txt"
  [[ $(block_sha "$d/n.txt") == "$(printf '%s\n\nbody\n' "$marker" | sha256sum | cut -d' ' -f1)" ]] || { echo "FAIL: block hash"; fails=1; }
  printf 'package_x() {\n  license=(MIT GPL-3.0-only)\n}\npackage_y() {\n  license=(MIT)\n}\n' >"$d/PKGBUILD"
  [[ $(licenses_of "$d/PKGBUILD" x) == "MIT GPL-3.0-only" ]] || { echo "FAIL: license= of x"; fails=1; }
  [[ $(licenses_of "$d/PKGBUILD" y) == "MIT" ]] || { echo "FAIL: license= of y"; fails=1; }
  [[ -z $(need "$d/PKGBUILD" x MIT GPL-3.0-only) ]] || { echo "FAIL: complete array reported incomplete"; fails=1; }
  [[ $(need "$d/PKGBUILD" y MIT LGPL-2.1-or-later) == "LGPL-2.1-or-later" ]] || { echo "FAIL: missing licence not reported"; fails=1; }
  ((fails == 0)) && echo "check-licenses selftest: PASS (5 cases)"
  return "$fails"
}

if [[ ${1:-} == --selftest ]]; then selftest; exit $?; fi
if out=$(check_tree "$root"); then
  echo "licenses: ok (Omarchy LICENSE verbatim, license= arrays complete, notices shipped)"
else
  echo "$out"
  echo "licenses: FAIL" >&2
  exit 1
fi
