#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QHash>
#include <QString>
#include <QStringList>

// user.xdg.tags (TagLogic) on local files, through the Linux extended attribute calls. Symbolic links are never
// followed: Linux keeps no user attributes on a link, and tagging a link must not tag its target. Unit tested on a
// file under the test sandbox (tests/unit/files/tst_tags.cpp). Thread-safe (the tag search reads from a worker thread).
namespace TagStore
{

enum class Support {
    Supported, // a local file or folder on a filesystem with user attributes
    Missing, // no such file
    Link, // a symbolic link
    NotRegular, // neither a regular file nor a folder (FIFO, socket, device): Linux keeps no user attributes there
    ReadOnly, // the attribute can't be written: no write permission, a read-only filesystem, an immutable file
    NoXattr, // the filesystem has no user extended attributes (or they are disabled)
};

// What one pass over a path tells: whether it can be tagged, the stored value and its tags (empty when unreadable).
struct Info {
    Support support = Support::Missing;
    QByteArray raw;
    QStringList tags;
};

// lstat, access and one lgetxattr, nothing else.
Info probe(const QString &path);

// Probe results kept for a short time (the selection's tag state is asked on every selection change: probing 1000
// items takes ~40-65 ms, a hash lookup does not). Files' own writes drop the entries they change (invalidate); another
// application's change shows after `ttlMs`. GUI thread only. Never use it to decide a write: read fresh (readRaw).
class Cache
{
public:
    explicit Cache(qint64 ttlMs = 3000, int maxEntries = 8192);
    const Info &info(const QString &path);
    void invalidate(const QString &path);
    void clear();

private:
    struct Entry {
        Info info;
        qint64 stamp = 0;
    };
    QHash<QString, Entry> m_entries;
    QElapsedTimer m_clock;
    qint64 m_ttlMs;
    int m_maxEntries;
};

// Whether `path` can be tagged by this process now (nothing is written). Symbolic links are not taggable (decided: a
// link is never followed, so its target is never tagged by accident, and Linux keeps no attributes on the link).
// Reading tags is possible on read-only items; only writing is refused.
Support support(const QString &path);

// The stored attribute value as it is (empty without one). Files edits this, not the parsed list, so what other
// applications wrote survives (TagLogic::applyTag).
QByteArray readRaw(const QString &path);

// Stores `value` as is; an empty value removes the attribute.
bool writeRaw(const QString &path, const QByteArray &value, QString *error = nullptr);

// The stored tags; empty when there are none, or the attribute cannot be read.
QStringList read(const QString &path);

// Stores exactly `tags` (replaces everything; Files itself edits through readRaw/writeRaw). Removes the attribute when the list is empty. False, with the system's reason in `error`, when the
// filesystem or the permissions refuse it.
bool write(const QString &path, const QStringList &tags, QString *error = nullptr);

} // namespace TagStore
