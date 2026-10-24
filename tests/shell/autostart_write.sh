#!/usr/bin/env bash
# Test for shell/overlay/write-autostart.sh (Open at Login): atomic write, only `<dir>/autostart/<plain name>.desktop`,
# nothing left behind, hostile paths refused. Works in a temporary tree.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/autostart.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
script=$root/shell/overlay/write-autostart.sh
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

dir=$tmp/config/autostart
text=$'[Desktop Entry]\nType=Application\nName=x\nExec=/bin/x\n'
sh "$script" "$dir/app.desktop" "$text" && [[ $(<"$dir/app.desktop") == "${text%$'\n'}" ]] && ok "writes the file (creates the directory)" || bad "write"
[[ $(stat -c %a "$dir/app.desktop") == 644 ]] && ok "mode 644" || bad "mode"
[[ $(ls -A "$dir" | wc -l) == 1 ]] && ok "no temporary file left" || bad "temporary file left: $(ls -A "$dir")"
# replacing an existing file
sh "$script" "$dir/app.desktop" "$text# again" && grep -q "# again" "$dir/app.desktop" && ok "replaces atomically" || bad "replace"

# refused: nothing is created
refuse() {
  local what=$1 path=$2 body=${3-x}
  local before
  before=$(find "$tmp" | sort)
  if sh "$script" "$path" "$body" 2>/dev/null; then bad "$what accepted"; return; fi
  [[ $(find "$tmp" | sort) == "$before" ]] && ok "$what refused, nothing written" || bad "$what refused but left files"
}
refuse "outside autostart" "$tmp/config/app.desktop"
refuse "not a desktop file" "$dir/app.txt"
refuse "hidden name" "$dir/.app.desktop"
refuse "parent reference" "$dir/../autostart/app.desktop"
refuse "parent reference in the middle" "$tmp/config/x/../autostart/app.desktop"
refuse "nested directory" "$dir/sub/app.desktop"
refuse "relative path" "app.desktop"
refuse "empty text" "$dir/empty.desktop" ""

# a read-only directory fails without a partial file
mkdir -p "$tmp/ro/autostart"
chmod 555 "$tmp/ro/autostart"
if sh "$script" "$tmp/ro/autostart/a.desktop" "x" 2>/dev/null; then
  [[ $EUID == 0 ]] && ok "read-only directory (root ignores modes)" || bad "wrote into a read-only directory"
else
  [[ -z $(ls -A "$tmp/ro/autostart") ]] && ok "read-only directory: nothing left" || bad "partial file left"
fi
chmod 755 "$tmp/ro/autostart"

exit $fail
