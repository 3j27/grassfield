#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QUrl>

// Per-folder view settings (docs/specs/files.md FP-14, decision F-3): the view and the arrangement the user chose for a
// folder, kept in a per-user state file keyed by the folder's URL (`files-views.json` in the Grassfield state directory,
// 0600, written atomically). Files never writes into the folder itself (macOS keeps these in `.DS_Store`): read-only,
// remote, Trash and search locations work alike and other applications never see a stray file. At most kMaxEntries
// folders; the least recently set one is dropped first.
class FolderViews
{
public:
    // A field that was never set for the folder reads as unset: the folder then uses the defaults.
    struct Entry {
        QString mode;        // icons | list | columns | gallery; empty: unset
        int sortKey = -1;    // 0 name, 1 kind, 2 date modified, 3 size; -1: unset
        int descending = -1; // 0 or 1; -1: unset

        bool isEmpty() const { return mode.isEmpty() && sortKey < 0 && descending < 0; }
        bool operator==(const Entry &o) const { return mode == o.mode && sortKey == o.sortKey && descending == o.descending; }
    };

    static constexpr int kVersion = 1;
    static constexpr int kMaxEntries = 2000;
    // A larger file is refused as broken (never parsed, never overwritten).
    static constexpr qint64 kMaxFileSize = 2 * 1024 * 1024;

    explicit FolderViews(const QString &file);

    QString file() const { return m_file; }
    // Reads the file again. Missing: no entries. Unparsable, too large or written by a newer version: no entries and
    // read-only for this session (a file this version cannot read back is never overwritten).
    void load();
    bool readOnly() const { return m_readOnly; }
    int count() const { return int(m_order.size()); }
    Entry entry(const QString &key) const { return m_entries.value(key); }
    // Merges the set fields of `fields` into the folder's entry, makes it the most recently set, drops the oldest past
    // kMaxEntries and writes the file. A file changed on disk since it was read (another Files process) is read first,
    // so its entries are kept. Returns false (with the reason) when nothing could be written.
    bool set(const QString &key, const Entry &fields, QString *error = nullptr);

    // The key of a location: its URL with a trailing slash removed and "." / ".." segments resolved, fully encoded (the
    // query of a search location is kept). Empty for an invalid or empty URL.
    static QString keyFor(const QUrl &url);
    // One stored entry from JSON; invalid fields read as unset.
    static Entry parse(const QJsonObject &object);
    static QJsonObject serialize(const QString &key, const Entry &entry);
    // The fields of `fields` that are set, over `base`.
    static Entry merged(const Entry &base, const Entry &fields);

private:
    bool save(QString *error);
    QDateTime stampOnDisk() const;

    QString m_file;
    QHash<QString, Entry> m_entries;
    // Keys from the least to the most recently set.
    QStringList m_order;
    bool m_readOnly = false;
    QDateTime m_stamp;
};
