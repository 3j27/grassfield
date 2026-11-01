#pragma once

#include "searchlogic.h"

#include <QFileSystemWatcher>
#include <QList>
#include <QObject>
#include <QString>
#include <QTimer>

// Saved searches (ADR-0027, the Finder's smart folders): one JSON file per search (SearchLogic::toJson) in
// `$XDG_DATA_HOME/grassfield/saved-searches/`, user data, 0600, written atomically. The folder is read again when it
// changes (another Files window, the user's own copy). A file that cannot be read (too large, not JSON, a newer version)
// is left as it is and not listed.
class SavedSearches : public QObject
{
    Q_OBJECT

public:
    // At most this many searches are read, each file at most this large.
    static constexpr int kMaxSearches = 200;
    static constexpr qint64 kMaxFileSize = 64 * 1024;

    struct Entry {
        SearchLogic::Saved saved;
        // The file's name in the folder (its key for the sidebar and removals).
        QString file;
    };

    // `folder`: the store's folder (the default one when empty).
    explicit SavedSearches(const QString &folder = QString(), QObject *parent = nullptr);

    static QString defaultFolder();
    QString folder() const { return m_folder; }
    const QList<Entry> &entries() const { return m_entries; }

    // Saves `saved` under a file named after it ("Name.json", "Name 2.json"... when taken by another search; the same
    // file when a search of that name exists, which is then replaced). Returns "" or why it failed.
    QString save(const SearchLogic::Saved &saved);
    bool remove(const QString &file);
    bool setSidebar(const QString &file, bool on);
    void reload();

signals:
    void changed();

private:
    QString m_folder;
    QList<Entry> m_entries;
    QFileSystemWatcher m_watcher;
    QTimer m_reloadTimer;
};
