#pragma once

#include <QDateTime>
#include <QList>
#include <QLocale>
#include <QString>
#include <QUrl>
#include <QVariant>

#include <functional>

class QCollator;

// Pure presentation logic of Grassfield Files (Qt Core only, no KIO): sort keys, size and date
// formatting, path bar segmentation and file name rules. Unit tested in tests/unit/files/.
namespace FileLogic
{

enum class SortKey { Name = 0, Kind = 1, Date = 2, Size = 3 };

struct SortEntry {
    QString name;
    QString kind; // MIME comment, e.g. "PNG image"
    QDateTime modified;
    qint64 size = -1; // -1 for folders (unknown)
    bool isDir = false;
};

// Negative when a sorts before b. With foldersFirst, folders precede files in both directions.
// `descending` reverses the primary key only; ties are broken by name (ascending), then by code points.
int compareEntries(const SortEntry &a, const SortEntry &b, SortKey key, bool descending, bool foldersFirst, const QCollator &collator);

// Default direction when a column is chosen: names and kinds ascending, dates and sizes descending.
bool defaultDescending(SortKey key);

// Decimal (SI) sizes like the macOS file manager: "Zero bytes", "1 byte", "999 bytes", "12 KB",
// "1.23 MB", "12.3 GB", "123 TB". Negative sizes (folders) give "--".
QString formatSize(qint64 bytes, const QLocale &locale = QLocale());

// "Today at 14:05", "Yesterday at 09:10", otherwise "<short date> at <short time>". Invalid gives "--".
QString formatDate(const QDateTime &when, const QDateTime &now, const QLocale &locale = QLocale());

struct Segment {
    QString label;
    QUrl url;
};

// Path bar and column view segments from the first visible ancestor to `url`:
// inside the home folder the first segment is the home folder (labelled with its name),
// other local paths start at the root (`rootLabel`), trash:/ starts with `trashLabel`,
// other schemes start at "<scheme>:/".
QList<Segment> pathSegments(const QUrl &url, const QString &homePath, const QString &rootLabel, const QString &trashLabel);

// A file name as shown in a message or a label: line breaks become a return symbol and the bidirectional override,
// embedding and isolate controls are written out ("<U+202E>"). The twin of ui/Grassfield/Ui/DisplayName.js (GF-105).
QString displayName(const QString &name);

// Names that differ only by Unicode normalization (NFC "e acute" and NFD "e" + combining acute) are the same name to a
// person: macOS compares them equal (GF-105). The file system keeps them apart, so Files checks collisions with this.
bool sameName(const QString &a, const QString &b);

// The entry of `names` that is the same name as `name` to a person but not the same string (an NFC/NFD twin), or "".
// Copying, moving or dropping an item next to such a twin would make two entries that look alike (GF-105).
QString equivalentName(const QStringList &names, const QString &name);

// The original path of a trashed item from its .trashinfo (the `Path=` line of the [Trash Info] group, percent-decoded), or ""
// (no such line, or a relative path: a trash outside the home volume, left to the system).
QString trashInfoOriginalPath(const QByteArray &trashinfo);

// Match text for the folder filter: canonically decomposed, combining marks dropped, case folded ("resume" finds
// "Résumé.txt" in either normalization form).
QString foldForMatch(const QString &text);

// Whether `name` contains the filter text under foldForMatch.
bool nameMatchesFilter(const QString &name, const QString &filter);

// A name a single file can take: not empty, not "." or "..", no '/', no NUL, at most 255 UTF-8 bytes.
bool isValidFileName(const QString &name);

// Characters to preselect when renaming: the name without its last extension; whole name for folders
// and for dot files without another dot.
int baseNameLength(const QString &name, bool isDir);

// First free name among "base", "base 2", "base 3", ... (`exists` tells whether a name is taken).
QString uniqueName(const QString &base, const std::function<bool(const QString &)> &exists);

// Name of a duplicate: "report copy.txt", then "report copy 2.txt"... `copyWord` is the translated "copy".
QString duplicateName(const QString &name, bool isDir, const QString &copyWord, const std::function<bool(const QString &)> &exists);

// Entries of KIO's Network place (remote:/) that Files does not show: the kio-extras "afc:" link to Apple mobile
// devices (an Apple trademark in its name, master-prompt §14). `item` is the entry's URL, `target` its link target.
bool hiddenNetworkEntry(const QUrl &item, const QUrl &target);

// The browser window size kept for the next window (ADR-0026 part 1, QSettings window/width and window/height): a side
// outside kMinKeptWindowSide..kMaxKeptWindowSide is never kept nor used, so a corrupt value never opens a giant or an
// invisible window (the window minimum then applies in QML, Main.qml newWindow).
constexpr int kMinKeptWindowSide = 200;
constexpr int kMaxKeptWindowSide = 16384;
// A stored side (any QSettings value): the side when it is an integer in bounds, else 0 (none kept).
int keptWindowSide(const QVariant &value);
// Whether a window of this size is kept (both sides in bounds).
bool keepsWindowSize(int width, int height);

} // namespace FileLogic
