#!/bin/bash
# The Dock's Name order is Files' (review of the Dock stacks: "file1, file10, file2 ... Zebra, Ecole" was not): one corpus of names
# (digits, case, accents, emoji, full width, CJK, other scripts, spaces, punctuation, leading dots) is made into files, listed by
# grassfield-stack-helper (ADR-0025) and sorted by Files' own comparison, and the orders must be identical, in several locales (the
# ICU collation is the user's: Swedish puts "ål" after z, Czech sorts "ch" after "h").
#  - Files' side: tests/shell/dock_name_order.d/collation_ref.cpp, compiled here with apps/files/src/filelogic.cpp as it is, and a
#    QCollator set as foldermodel.cpp sets it (this script fails if foldermodel.cpp stops setting it that way);
#  - the Dock's side: the helper's window of the folder (the helper compiles filelogic.cpp in, so the two agree by construction:
#    this is the proof that nothing between the comparison and the output changes the order).
# Prints PASS or FAIL lines; exits 1 on a failure. Needs g++ and Qt 6 Core headers (the Files app needs them too).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/name-order.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

# the settings the reference assumes are still the ones Files uses
for want in 'setNumericMode(true)' 'setCaseSensitivity(Qt::CaseInsensitive)' 'locale.language() == QLocale::C'; do
  if ! grep -q -F "$want" apps/files/src/foldermodel.cpp; then
    echo "FAIL dock_name_order: apps/files/src/foldermodel.cpp no longer has '$want': update collation_ref.cpp and the helper's collator"
    fail=1
  fi
  if ! grep -q -F "$want" apps/stack-helper/src/stacklogic.cpp; then
    echo "FAIL dock_name_order: apps/stack-helper/src/stacklogic.cpp no longer has '$want': its collator is not Files'"
    fail=1
  fi
done

if ! command -v g++ >/dev/null 2>&1 || ! pkg-config --exists Qt6Core 2>/dev/null; then
  echo "FAIL dock_name_order: g++ or Qt6Core headers missing (needed to run Files' own comparison)"
  exit 1
fi
if ! g++ -std=c++17 -fPIC -I apps/files/src $(pkg-config --cflags Qt6Core) tests/shell/dock_name_order.d/collation_ref.cpp apps/files/src/filelogic.cpp $(pkg-config --libs Qt6Core) -o "$tmp/ref" 2>"$tmp/cc.log"; then
  echo "FAIL dock_name_order: the reference did not build"
  tail -5 "$tmp/cc.log"
  exit 1
fi
helper=${GRASSFIELD_STACK_HELPER:-$root/.dev/build/grassfield-stack-helper}
[[ -x $helper ]] || apps/stack-helper/build-direct.sh >/dev/null 2>&1
if [[ ! -x $helper ]]; then
  echo "FAIL dock_name_order: the helper does not build"
  exit 1
fi

# the corpus as files (hidden names are not listed, by any of the two)
mkdir -p "$tmp/dir"
while IFS= read -r n; do
  [[ -n $n && $n != .* ]] && : >"$tmp/dir/$n"
done <tests/shell/dock_name_order.d/corpus.txt
grep -v '^\.' tests/shell/dock_name_order.d/corpus.txt >"$tmp/corpus.txt"
count=$(wc -l <"$tmp/corpus.txt")

cat >"$tmp/names.py" <<'EOF'
import sys
last = None
for line in sys.stdin.buffer.read().split(b"\n"):
    if line.startswith(b"W\x1f"):
        last = line
f = last.split(b"\x1f")
n = int(f[3])
for i in range(n):
    name = f[4 + 5 * i].decode("utf-8", "replace")
    name = name.replace("\\u", "\x1f").replace("\\r", "\r").replace("\\n", "\n").replace("\\\\", "\\")
    sys.stdout.write(name + "\n")
EOF

for locale in en_US.UTF-8 fr_FR.UTF-8 sv_SE.UTF-8 cs_CZ.UTF-8 de_DE.UTF-8 tr_TR.UTF-8; do
  env -u LC_ALL LANG="$locale" "$tmp/ref" <"$tmp/corpus.txt" >"$tmp/expected.txt"
  # the helper ends with its stdin: one second of life is enough for the first window of 1,000 names
  sleep 1.5 | env -u LC_ALL LANG="$locale" "$helper" "$tmp/dir" name 1000 >"$tmp/out.txt" 2>/dev/null
  if ! python3 -I "$tmp/names.py" <"$tmp/out.txt" >"$tmp/got.txt" 2>/dev/null; then
    echo "FAIL dock_name_order: $locale: the helper wrote no window"
    fail=1
    continue
  fi
  if cmp -s "$tmp/expected.txt" "$tmp/got.txt"; then
    echo "PASS dock_name_order: $locale: the helper sorts $count names as Files does"
  else
    echo "FAIL dock_name_order: $locale: the orders differ, first at line $(cmp "$tmp/expected.txt" "$tmp/got.txt" 2>&1 | grep -o 'line [0-9]*' | head -1)"
    diff "$tmp/expected.txt" "$tmp/got.txt" | head -6 | cut -c1-200
    fail=1
  fi
done
exit $fail
