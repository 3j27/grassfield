#pragma once

#include <QByteArray>
#include <QString>

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

} // namespace FolderStyleLogic
