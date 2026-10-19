#pragma once

#include <QByteArray>
#include <QList>
#include <QPair>
#include <QSet>
#include <QString>
#include <QUrl>

// A folder's own look in Grassfield Files and on the desktop ("Customize Folder…", macOS 26): a colour and an optional
// symbol or emoji drawn on the folder icon. Pure logic (Qt Core only, unit tested in tests/unit/files/tst_folderstyle.cpp).
//
// Storage: the extended attribute user.grassfield.folder, a small UTF-8 JSON object: {"v":1,"color":"#ff9500","glyph":"🎵"}.
// `color` is "#rrggbb" (lower case), "accent" (follows the accent colour) or "theme" (the icon theme's own colour even
// when a global folder colour is set); a missing `color` follows the global setting (icons.folderColor); a missing
// `glyph` draws nothing. Keys this version does not know are kept as they are when the value is edited (a newer
// version's data survives). Another application's attributes are never touched: only this attribute is read or written.
// The same format is parsed by ui/Grassfield/Ui/FolderStyle.js for the shell (tests/unit/tst_foldercolors.qml).
namespace FolderStyleLogic
{

struct Style {
    QString color; // "" = follows the global setting
    QString glyph; // "" = none
    bool isEmpty() const { return color.isEmpty() && glyph.isEmpty(); }
    bool operator==(const Style &other) const { return color == other.color && glyph == other.glyph; }
    bool operator!=(const Style &other) const { return !(*this == other); }
};

// "user.grassfield.folder".
const char *attributeName();

// "theme", "accent" or a six-digit hex colour (any case).
bool validColor(const QString &color);
// A valid colour as stored (hex in lower case), "" for anything else.
QString normalizeColor(const QString &color);
// The symbol rule, the same in ui/Grassfield/Ui/FolderStyle.js (shared test vectors): the first grapheme cluster of
// `glyph` (white space around it trimmed); "" when empty, longer than 16 UTF-16 units (a pasted sentence is not a
// symbol), or when it holds a control, format (bidi marks, zero width space; the emoji joiner and tag characters are
// allowed), line/paragraph separator, lone surrogate or replacement character.
QString normalizeGlyph(const QString &glyph);

// The classes of a code point for that rule (a bit mask). The cluster rule is UAX #29 (extended grapheme clusters, the
// whole of GB3 to GB13 including GB9b prepended characters and GB9c Indic conjuncts) over the Unicode properties
// Grapheme_Cluster_Break, Extended_Pictographic and Indic_Conjunct_Break; the emoji rule uses the Emoji property. The
// properties are read from ICU by scripts/dev/gen-glyph-tables.sh into apps/files/src/graphemedata.inc (this side) and
// ui/Grassfield/Ui/GraphemeData.js (the QML side, ui/Grassfield/Ui/FolderStyle.js, the same algorithm): one set of data,
// and both are held to the same answers by tests/fixtures/glyph-vectors.json and checked against ICU's own segmenter by
// scripts/dev/glyph-icu-compare.sh. Qt's own segmenter is not used because it cuts Indic conjuncts differently.
enum GlyphClass : unsigned {
    GlyphExtend = 1u << 0,       // GCB=Extend (marks, ZWNJ, emoji modifiers, tag characters): attach to the previous character
    GlyphSpacing = 1u << 1,      // GCB=SpacingMark (Thai and Lao AM included): attach, but end an emoji sequence
    GlyphJoiner = 1u << 2,       // U+200D
    GlyphRegional = 1u << 3,     // regional indicator (flags come in pairs)
    GlyphPictograph = 1u << 4,   // Extended_Pictographic: what a joiner can join
    GlyphHangulL = 1u << 5,
    GlyphHangulV = 1u << 6,
    GlyphHangulT = 1u << 7,
    GlyphConsonant = 1u << 8,    // InCB=Consonant
    GlyphLinker = 1u << 9,       // InCB=Linker (virama)
    GlyphControl = 1u << 10,     // GCB=Control/CR/LF: ends a cluster
    GlyphRejected = 1u << 11,    // a symbol holding it is refused: control, format, separator, lone surrogate, U+FFFD
    GlyphEmoji = 1u << 12,       // drawn as an emoji unless the text selector follows (Emoji property; not the ASCII digits, # and *)
    GlyphPrepend = 1u << 13,     // GCB=Prepend: attaches to the character after it (GB9b)
    GlyphIncbExtend = 1u << 14   // InCB=Extend: keeps an Indic conjunct going
};
// The classes of `cp` (Hangul syllables, U+AC00..U+D7A3, are computed, not listed: no class bit).
unsigned glyphClasses(uint cp);
// Whether the symbol is drawn as a colour emoji (opaque, in its own colours) rather than as an engraved shade: the
// emoji presentation selector (U+FE0F), a keycap, or a character with the Emoji property, unless the text selector
// (U+FE0E) is in it. Characters of text presentation by default (an umbrella, a heart) count as emoji without the text
// selector because the fonts of this system draw them as colour glyphs.
bool isEmoji(const QString &glyph);

// After a cut-and-paste: the folders whose look follows, as (from, to). Only a folder the job really created at
// destination/name counts: with Skip in the conflict dialog nothing is created, with Rename the folder lands under another
// name, and a look must not end up on a different folder that happens to have the name.
QList<QPair<QUrl, QUrl>> followingPaste(const QList<QUrl> &sources, const QUrl &destination, const QSet<QUrl> &created);

// The style held by a stored value. Anything that is not a JSON object, or holds invalid fields, reads as empty fields
// (an invalid colour is dropped, the glyph is normalised).
Style parse(const QByteArray &stored);

// `stored` with `style` applied: colour and glyph set to exactly `style`'s (an empty field removes its key), every other
// key and the version kept as stored. Returns an empty value when nothing is left (remove the attribute). A stored
// value that is not a JSON object is replaced (it holds nothing of a newer version); one larger than the read limit
// (tooLargeToEdit) must not be edited at all: it would drop the keys this version cannot read.
QByteArray apply(const QByteArray &stored, const Style &style);

// A stored value larger than the limit the reader accepts (4096 bytes): it reads as empty, and editing it would lose its
// content, so callers refuse to write instead.
bool tooLargeToEdit(const QByteArray &stored);

// The value for `style` alone (apply to nothing).
QByteArray serialize(const Style &style);

// Debounce with a maximum wait: how long to wait (ms) after an event that follows `sinceFirstMs` of continuous activity
// (events closer than `quietMs` to each other), so that the work runs after `quietMs` of quiet, and at the latest
// `maxWaitMs` after the first event of the burst even if the activity never stops.
int debounceDelay(int quietMs, int maxWaitMs, qint64 sinceFirstMs);

} // namespace FolderStyleLogic
