#!/usr/bin/env bash
# One keyboard focus ring (ADR-0039 step 7, G7), checked statically on the surfaces the step covers: the shared FocusRing
# outside the shape, shown for keyboard focus only (a Control's visualFocus, KeyFocus.active for any other item, a text
# field's activeFocus), in Appearance.focusRingColor. Fails when a hand-made ring comes back there:
#  * a border that grows to the focus outline when the item has the focus (`border.width: x.activeFocus ? ...`, the same with
#    visualFocus): a ring drawn inside the shape, shown after a click too;
#  * a ring border in the bare accent in the shell's surfaces (the accent fails 3:1 in the yellow; focusRingColor falls back to
#    the text colour), the Overview's drag ghost excepted (a drag, not a focus).
# The behaviour is tests/unit/tst_keyfocus.qml and tst_qsfocus.qml. Files (step 23), the menu bar's BarButton and the Dock
# (step 25) and the Store (step 24) are outside this step.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

shell_dirs=(shell/overlay shell/notifications shell/launchpad shell/overview shell/switcher shell/widgets shell/stages)
scope=("${shell_dirs[@]}" ui/Grassfield/Ui apps/settings/qml apps/preview/qml)

hand_made=$(grep -rnE --include=*.qml "border\.width: [A-Za-z0-9_.]*(activeFocus|visualFocus)[^?]*\? Tokens\.controlFocusOutline" "${scope[@]}")
desc="no ring drawn inside a shape from the focus (the shared FocusRing instead)${hand_made:+: $hand_made}"
check test -z "$hand_made"

accent=$(grep -rnE --include=*.qml "border\.color: Appearance\.colors\.accent$" "${shell_dirs[@]}" | grep -v "^shell/overview/OverviewWindow.qml:")
desc="no ring border in the bare accent in the shell's surfaces${accent:+: $accent}"
check test -z "$accent"

desc="the Overview keeps one accent border, its drag ghost"
check test "$(grep -cE "border\.color: Appearance\.colors\.accent$" shell/overview/OverviewWindow.qml)" -eq 1

desc="the Notification Center's Clear All takes the keyboard and is the Tab stop before the cards"
check bash -c 'awk "/id: clearAllButton/,/MouseArea \\{/" "$0" | grep -q "activeFocusOnTab: true" \
  && awk "/id: clearAllButton/,/MouseArea \\{/" "$0" | grep -q "visible: clearAllFocus.active" \
  && grep -q "headTarget: clearAllButton" "$0"' shell/notifications/NotificationCenter.qml

exit $fail
