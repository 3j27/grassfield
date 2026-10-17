#pragma once

#include <QDateTime>
#include <QList>
#include <QLocale>
#include <QString>
#include <QUrl>

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

// A name a single file can take: not empty, not "." or "..", no '/', no NUL, at most 255 UTF-8 bytes.
bool isValidFileName(const QString &name);

// Characters to preselect when renaming: the name without its last extension; whole name for folders
// and for dot files without another dot.
int baseNameLength(const QString &name, bool isDir);

// First free name among "base", "base 2", "base 3", ... (`exists` tells whether a name is taken).
QString uniqueName(const QString &base, const std::function<bool(const QString &)> &exists);

// Name of a duplicate: "report copy.txt", then "report copy 2.txt"... `copyWord` is the translated "copy".
QString duplicateName(const QString &name, bool isDir, const QString &copyWord, const std::function<bool(const QString &)> &exists);

} // namespace FileLogic
