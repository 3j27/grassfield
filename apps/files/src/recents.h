#pragma once

#include <QByteArray>
#include <QDateTime>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>
#include <QThread>
#include <QUrl>
#include <QVariantList>

// Recents (docs/specs/files.md "Views and selection", decision F-5): the local files listed in recently-used.xbel, the
// freedesktop list of recently used files that GTK and KDE applications write and the shell's Recent Items read. Files
// only reads it. Shown as the location grassfield-recents:/ (internal to Files, never handed to KIO), like a tag search.
namespace Recents
{

// At most this many files are shown, the most recently used.
constexpr int kMaxItems = 500;

struct Entry {
    QString path;
    QDateTime used;
};

// The local files of an xbel document, the most recently used first, each once. `used` is the latest of the bookmark's
// `modified` and `visited` times and its applications' `modified` times. Other schemes, relative or broken entries and
// entries without a time are skipped. Pure: nothing is checked on disk.
QList<Entry> parse(const QByteArray &xbel);

QString scheme();
QUrl locationUrl();
bool isRecentsUrl(const QUrl &url);
// $XDG_DATA_HOME/recently-used.xbel ($HOME/.local/share without XDG_DATA_HOME).
QString xbelPath();

// A recent file renamed or moved while Files runs stays a recent file under its new path (recently-used.xbel keeps the
// old one): the loaders read it there. Only an entry last used before the rename follows it (a new file at the old path,
// used since, is that file). Process-wide, GUI thread only.
struct Rename {
    QString to;
    QDateTime at;
};
void noteRenamed(const QString &from, const QString &to, const QDateTime &at = QDateTime::currentDateTimeUtc());
// Old path -> where it went and when, for the renames noted so far (chains followed, each from its own time).
QHash<QString, Rename> renamed();

} // namespace Recents

// Reads the list on its own thread: an entry on a network mount that does not answer must not stop the window. parse(),
// each path through `renames` (Recents::renamed(): entries used before the rename), then the entries that are regular
// files (links followed), each once,
// at most Recents::kMaxItems. One run per object; the caller deletes it (deleteLater on finished).
class RecentsLoader : public QThread
{
    Q_OBJECT

public:
    RecentsLoader(quint64 generation, const QString &file, const QHash<QString, Recents::Rename> &renames = {});

signals:
    // `used` holds the QDateTime of each path.
    void loaded(quint64 generation, const QStringList &paths, const QVariantList &used);

protected:
    void run() override;

private:
    const quint64 m_generation;
    const QString m_file;
    const QHash<QString, Recents::Rename> m_renames;
};
