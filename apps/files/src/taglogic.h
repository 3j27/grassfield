#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

// Tags of Grassfield Files: pure logic (Qt Core only, unit tested in tests/unit/files/tst_tags.cpp).
//
// Storage: the extended attribute user.xdg.tags of the freedesktop "Common Extended Attributes" convention, also read
// and written by Dolphin, Baloo and KFileMetaData::UserMetaData: UTF-8 text, tags separated by commas. Tags written
// by other tools are kept as they are. The seven colour tags are stored under fixed English keys (Red, Orange, Yellow,
// Green, Blue, Purple, Gray), so the attribute does not depend on the UI language; the UI shows translated names.
namespace TagLogic
{

constexpr int kColorCount = 7;

// "user.xdg.tags".
const char *attributeName();

// The tags of an attribute value: split at commas, surrounding white space trimmed, empty entries dropped, exact
// duplicates dropped (the first one kept). Invalid UTF-8 decodes to U+FFFD.
QStringList parse(const QByteArray &value);

// The attribute value for `tags`: commas and line breaks inside a tag become spaces (a comma would split it), white
// space trimmed, empty entries and duplicates dropped, joined with ",". Empty means: remove the attribute.
QByteArray serialize(const QStringList &tags);

// Edits the stored attribute value without touching what Files does not own. `tag` is added as one more entry at the
// end (unless an entry of that name is there already), or every entry of that name is removed. Every other entry stays
// exactly as stored, byte for byte and in order: surrounding spaces, duplicates, line breaks, invalid UTF-8, other
// applications' tags that differ only in case ("red" is not the colour tag "Red"). An entry is `tag`'s when its bytes,
// white space trimmed, equal the tag's stored name (a colour tag's fixed key, any other tag as given). The result is
// empty when nothing is left: remove the attribute.
QByteArray applyTag(const QByteArray &stored, const QString &tag, bool on);

// Whether `stored` holds an entry that applyTag(..., tag, false) would remove (exact name).
bool ownsTag(const QByteArray &stored, const QString &tag);

// 0..6 for a colour tag (its key, case-insensitive), -1 for any other tag.
int colorIndex(const QString &tag);

// Stored key of colour `index` ("Red", ...), empty when out of range.
QString colorKey(int index);

// The name shown for a tag: a colour tag's translated name, any other tag as stored.
QString displayName(const QString &tag);

// Same tag: colour tags compare case-insensitively ("red" is Red), other tags exactly.
bool sameTag(const QString &a, const QString &b);
bool hasTag(const QStringList &tags, const QString &tag);

// `tags` with `tag` added at the end (unless already there) or with every entry of it removed.
QStringList withTag(const QStringList &tags, const QString &tag, bool on);

// Display order: colour tags in palette order (keys normalised), then the other tags in stored order.
QStringList displayOrder(const QStringList &tags);

// The sidebar's tags after Files saw `seen` on items: `known` plus every tag of `seen` that is neither known nor in
// `hidden` (removed from the sidebar by the user), colour tags first, at most `max`.
QStringList mergeKnown(const QStringList &known, const QStringList &hidden, const QStringList &seen, int max);

// Palette indices of the colour tags among `tags`, in palette order.
QList<int> colorIndices(const QStringList &tags);

// For a selection: per colour, 0 when no item has it, 1 when some do, 2 when all do. `tagLists` holds one tag list per
// item; an empty selection has state 0 everywhere.
QList<int> colorStates(const QList<QStringList> &tagLists);

// Tag search locations (the sidebar's Tags section): grassfield-tag:/<tag>?in=<folder url>, files tagged `tag` in
// `folder` and below. Internal to Files, never handed to KIO.
QString searchScheme();
QUrl searchUrl(const QString &tag, const QUrl &folder);
bool isSearchUrl(const QUrl &url);
QString searchTag(const QUrl &url);
QUrl searchFolder(const QUrl &url);

} // namespace TagLogic
