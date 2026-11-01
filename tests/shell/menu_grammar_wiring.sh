#!/usr/bin/env bash
# One menu grammar (ADR-0039 step 8, G17), checked statically on the shell's hand-built menus: they need Quickshell (the
# behaviour of MenuHeader and PopupMenu's headers is tests/unit/tst_popupmenu.qml; the look is the nested pass). Fails when
# one of these drifts again from PopupMenu's metrics:
#  * every section title is the shared MenuHeader (the caption size in bold, the secondary colour, a row tall, at the rows'
#    leading edge): PopupMenu's `header` rows, the sound menu's Output (after the check column of its device rows) and the
#    tiling popover's sections, which were 13 pt (docs/specs/tiling.md asks for the menu header style);
#  * the sound menu's rows sit a row tall with no gap between them, and one highlight shows: the pointer moving onto a
#    device row gives it the focus, so a focused row and a hovered one are never both lit;
#  * the tiling popover's rows and glyphs take the menus' selection with the label or glyph white on it (the spec's "accent
#    fill with white glyphs"), not a neutral tint;
#  * the stack's list is a menu: a row's icon at the inset in the menus' icon size, its label after the icon and its gap,
#    and no extra half row before the separator band of the Open in Files row.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

desc="PopupMenu's header rows are the shared MenuHeader, with the menu's check column"
check bash -c 'awk "/id: headerComponent/,/^                }$/" "$0" | grep -q "MenuHeader {" \
  && awk "/id: headerComponent/,/^                }$/" "$0" | grep -q "checkColumn: root.checkColumns\\[row.index\\] === true"' \
  ui/Grassfield/Ui/PopupMenu.qml

desc="the sound menu titles its Output section with MenuHeader, after the check column"
check bash -c 'awk "/MenuHeader \\{/,/\\}/" "$0" | grep -q "text: qsTr(\"Output\")" \
  && awk "/MenuHeader \\{/,/\\}/" "$0" | grep -q "checkColumn: true"' shell/overlay/VolumeMenu.qml

desc="the sound menu's rows have no gap between them"
check bash -c '! awk "/id: column/,/^        [A-Z]/" "$0" | grep -q "spacing:"' shell/overlay/VolumeMenu.qml

desc="the sound menu lights one device row: the focused one, which the pointer moves"
check bash -c 'grep -q "highlighted: deviceRow.activeFocus && (!deviceRow.pointerFocus || rowHover.hovered)$" "$0" \
  && grep -q "deviceRow.forceActiveFocus(Qt.MouseFocusReason)" "$0" \
  && ! grep -q "hover.hovered" "$0"' shell/overlay/VolumeMenu.qml

desc="a sound menu row the pointer lit goes dark when the pointer leaves it (review of #88)"
check bash -c 'grep -q "deviceRow.pointerFocus = true;" "$0" \
  && grep -q "deviceRow.pointerFocus = false" "$0" && grep -q "id: rowHover" "$0"' shell/overlay/VolumeMenu.qml

desc="the tiling popover's section titles are MenuHeader (its glyph sections and Layouts), none hand-drawn"
check bash -c 'test "$(grep -c "MenuHeader {" "$0")" -eq 2 && ! grep -q "typographyMenuBoldWeight" "$0"' shell/overlay/TilingPopover.qml

desc="the tiling popover's rows and glyphs take the menus' selection, white on it, not a neutral tint"
check bash -c 'test "$(grep -c "color: Appearance.colors.selection$" "$0")" -eq 2 \
  && test "$(grep -c "highlighted ? Appearance.colors.selectionText : Appearance.colors.text" "$0")" -eq 2 \
  && ! grep -q "withAlpha(Appearance.colors.text, Tokens.materialHoverOpacity)" "$0"' shell/overlay/TilingPopover.qml

desc="the stack's list rows: the icon in the menus' icon size, the label after it and its gap (MenuItem's)"
check bash -c 'awk "/id: listView/,/^        }$/" "$0" | grep -q "size: Tokens.menuIconSize" \
  && awk "/id: listView/,/^        }$/" "$0" | grep -q "x: Tokens.menuItemPadding + Tokens.menuIconSize + Tokens.spacingSm"' \
  shell/overlay/StackPopup.qml

desc="the stack's list ends with the separator band and Open in Files, no extra half row"
check bash -c '! grep -q "Tokens.menuItemHeight / 2" "$0" \
  && grep -q "y: root.view === \"list\" ? openRow.y - height" "$0"' shell/overlay/StackPopup.qml

exit $fail
