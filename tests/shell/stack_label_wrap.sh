#!/usr/bin/env bash
# Capture defect 8: the label of a Dock stack's Grid cell (shell/overlay/StackPopup.qml) wraps at word boundaries and is truncated
# in the middle, as macOS does, never split inside a word. tests/unit/tst_stacklabel.qml proves the behaviour of those Text
# properties; this check holds the real label to them: the Text of the Grid cell under the file name must carry wrapMode
# Text.WordWrap, elide Text.ElideMiddle and maximumLineCount 2, and no Text.WrapAnywhere may come back in the file.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
f=shell/overlay/StackPopup.qml
fail=0
check() { # <description> <condition exit status>
  if [[ $2 -eq 0 ]]; then echo "PASS stack_label_wrap: $1"; else echo "FAIL stack_label_wrap: $1"; fail=1; fi
}
# The Text block that shows the grid cell's name: from `text: DisplayName.text(cell.modelData.name)` up to its closing brace.
block=$(awk '/text: DisplayName.text\(cell.modelData.name\)/ { on = 1 } on { print } on && /^                }$/ { exit }' "$f")
[[ -n $block ]] || { echo "FAIL stack_label_wrap: the Grid cell's label was not found in $f"; exit 1; }
grep -q 'wrapMode: Text.WordWrap' <<<"$block"; check "the Grid label wraps at word boundaries" $?
grep -q 'elide: Text.ElideMiddle' <<<"$block"; check "the Grid label is truncated in the middle" $?
grep -q 'maximumLineCount: 2' <<<"$block"; check "the Grid label has two lines at most" $?
! grep -q 'WrapAnywhere\|WrapAtWordBoundaryOrAnywhere' "$f"; check "no mid-word wrapping in the Dock stack" $?
exit $fail
