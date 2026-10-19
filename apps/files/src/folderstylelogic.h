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
// The first grapheme cluster of `glyph` (white space around it trimmed), "" when empty, a control character or longer
// than a sane cluster (a pasted sentence is not a symbol).
QString normalizeGlyph(const QString &glyph);

// The style held by a stored value. Anything that is not a JSON object, or holds invalid fields, reads as empty fields
// (an invalid colour is dropped, the glyph is normalised).
Style parse(const QByteArray &stored);

// `stored` with `style` applied: colour and glyph set to exactly `style`'s (an empty field removes its key), every other
// key and the version kept as stored. Returns an empty value when nothing is left (remove the attribute). A stored
// value that is not a JSON object is replaced.
QByteArray apply(const QByteArray &stored, const Style &style);

// The value for `style` alone (apply to nothing).
QByteArray serialize(const Style &style);

} // namespace FolderStyleLogic
