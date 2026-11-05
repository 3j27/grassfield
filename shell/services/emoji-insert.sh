#!/bin/sh
# emoji-insert.sh GLYPH OMARCHY_INSERT: inserts GLYPH into the focused window (Emoji & Symbols, ADR-0045 OC-3; docs/specs/
# clipboard.md ES-7), run by shell/services/Emoji.qml once the window the panel opened over is active again. Omarchy's own
# omarchy-menu-emoji-insert (found in PATH, else at OMARCHY_INSERT: $OMARCHY_PATH/bin/omarchy-menu-emoji-insert) copies the
# glyph with `wl-copy --sensitive` (the clipboard history does not record it) and sends Shift+Insert; without it wtype types the
# glyph when it is installed; without either nothing is done. The first line of output says which ran: "omarchy", "wtype" or
# "missing" (the shell writes the journal line). GLYPH is only ever an argument, never evaluated. tests/shell/emoji_insert.sh.
glyph=$1
fallback=$2
[ -n "$glyph" ] || exit 2
insert=$(command -v omarchy-menu-emoji-insert 2>/dev/null) || insert=$fallback
if [ -n "$insert" ] && [ -x "$insert" ] && [ ! -d "$insert" ]; then
  echo omarchy
  exec "$insert" "$glyph"
fi
if command -v wtype >/dev/null 2>&1; then
  echo wtype
  exec wtype -- "$glyph"
fi
echo missing
