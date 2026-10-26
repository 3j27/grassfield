#pragma once

#include <QByteArray>
#include <QDateTime>
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

} // namespace Recents

// Reads the list on its own thread: an entry on a network mount that does not answer must not stop the window. parse(),
// then the entries that are regular files (links followed), at most Recents::kMaxItems. One run per object; the caller
// deletes it (deleteLater on finished).
class RecentsLoader : public QThread
{
    Q_OBJECT

public:
    RecentsLoader(quint64 generation, const QString &file);

signals:
    // `used` holds the QDateTime of each path.
    void loaded(quint64 generation, const QStringList &paths, const QVariantList &used);

protected:
    void run() override;

private:
    const quint64 m_generation;
    const QString m_file;
};
