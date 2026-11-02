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
# Step 8 (the owner's decision of 2026-10-31): a surface that gives an item the focus when it opens shows that ring after a
# key only. Popups records how the open popup was opened (openedByPointer: the button held on the bar, or a pointer action run
# through Popups.withPointer: the overlay's share of the bar strip, a menu item's click), and the volume menu, Force Quit and
# the stack hand it to their KeyFocus. Fails when one of these links is cut. Popups needs Quickshell: a KeyFocus bound so is
# tests/unit/tst_keyfocus.qml, a menu item's click or key tests/unit/tst_popupmenu.qml. A stack opened by a click on the Dock
# still shows its ring until the Dock (step 25) runs that click through Popups.withPointer.
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

desc="Popups.open records how the popup was opened, before the Overlay creates it"
check bash -c 'awk "/function open\(popupKind/,/^    }$/" "$0" \
  | awk "/openedByPointer = root.pointerHeld \|\| root.pointerActing;/ { o = NR } /kind = popupKind;/ { k = NR }
         END { exit !(o && k && o < k) }"' shell/services/Popups.qml

desc="the overlay's share of the bar strip opens menus as the pointer (moving onto a title, a press on one)"
check bash -c 'grep -q "Popups.withPointer(true, () => strip.bar.trackAt(" "$0" \
  && grep -q "Popups.withPointer(true, () => strip.bar.pressAt(" "$0" \
  && test "$(grep -c "strip\.bar\.\(trackAt\|pressAt\)(" "$0")" -eq 2' shell/overlay/Overlay.qml

desc="the Grassfield menu opens Force Quit as the item was chosen (a click or Return)"
check bash -c 'grep -q "onActivated: (item, byPointer) =>" "$0" \
  && grep -q "Popups.withPointer(byPointer, () => Popups.openCentered(\"forcequit\", {}));" "$0"' shell/overlay/SystemMenu.qml

for f in shell/overlay/VolumeMenu.qml shell/overlay/ForceQuitPanel.qml shell/overlay/StackPopup.qml; do
  desc="$f: the focus it gives on open is the pointer's after a click (KeyFocus.pointer)"
  check grep -q "pointer: Popups.openedByPointer" "$f"
done

exit $fail
