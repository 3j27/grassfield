#pragma once

#include "folderstylelogic.h"

#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

#include <functional>
#include <memory>

class QThread;

// Where a folder's own look (FolderStyleLogic) is kept, and how it is read and written.
//
// Primary: the extended attribute user.grassfield.folder on the folder itself, so the look travels with the folder
// (rename, move on the same volume, copy with attributes) and is private to nobody. Only that attribute is read or
// written; every other attribute (tags, other applications') is never touched. A read that fails (permission, I/O
// error, vanished folder) aborts the write: nothing is replaced from a guess.
//
// Fallback: a per-user store, `folder-styles.json` next to grassfield.json (GRASSFIELD_CONFIG_HOME, else
// $XDG_CONFIG_HOME/grassfield), used when the attribute cannot be written: a filesystem without user attributes (FAT,
// exFAT, NTFS, some network mounts), a read-only folder or volume, an immutable folder. Entries are keyed by the cleaned
// absolute path (a move outside Files loses them; the attribute does not), written atomically (QSaveFile, mode 0600).
// An entry wins over the attribute (it is the user's explicit choice on this machine). Entries follow Files' renames and
// moves of the folder; entries of folders that vanished are pruned by a worker thread after a write (never a stat of a
// store entry on the GUI thread, and only for entries on a mounted local filesystem: a dead network mount or an
// unplugged volume is never touched, its entries are kept); at most kMaxFallbackEntries entries. A store that cannot be parsed is
// never overwritten (writes that need it are refused with a reason). Format:
//   {"version":1,"serial":N,"folders":{"/abs/path":{"color":"#rrggbb","glyph":"x"}}}
// `serial` also moves on every successful attribute write: it is the change signal for other processes (the desktop
// watches this file and reads the attributes of its folders again).
//
// Reading costs one lgetxattr per folder shown (plus a hash lookup); callers cache the result per row. Not thread safe
// (GUI thread); unit tested in tests/unit/files/tst_folderstyle.cpp.
class FolderStyleStore
{
public:
    // The most entries the store takes. Entries beyond it that are already in a file are kept, never dropped on a write;
    // a new entry is refused with a reason once the store is full (after entries of vanished folders are pruned).
    static constexpr int kMaxFallbackEntries = 20000;

    explicit FolderStyleStore(const QString &fallbackFile = QString());
    ~FolderStyleStore();
    FolderStyleStore(const FolderStyleStore &) = delete;
    FolderStyleStore &operator=(const FolderStyleStore &) = delete;

    // The filesystems the pruner may look at, from /proc/self/mountinfo (reading it never touches a mount) and /etc/fstab.
    struct Mounts {
        struct Mount {
            QString point;
            QString type;
        };
        QList<Mount> mounted;
        QStringList declared; // mount points named in fstab
        static Mounts parse(const QByteArray &mountinfo, const QByteArray &fstab);
        static Mounts system();
        // Whether `path` lies on a currently mounted local disk filesystem (so a stat of it cannot hang and a missing
        // path really is gone): not on a network or FUSE or removable filesystem, and not under a mount point (fstab, or
        // /run/media, /media, /mnt by convention) that is not mounted right now.
        bool isLocalAndMounted(const QString &path) const;
    };
    // The keys among `keys` whose folder is gone: judged only for paths on a mounted local filesystem (lstat there), plus
    // the paths of that kind under a gone one. Runs on any thread.
    static QStringList goneEntries(const QStringList &keys, const Mounts &mounts);
    // Test hooks: the mounts the pruner uses (default: Mounts::system() when a pruning starts) and an observer called
    // for every stat the pruner does (path, on which thread).
    void setMountsForTests(const Mounts &mounts);
    static void setStatObserverForTests(std::function<void(const QString &)> observer);

    // Pruning of entries of vanished folders, in a worker thread: started after a write (at most once a minute, or at once
    // when a new entry finds the store full); its result is applied by collectPruned, which every write/move/drop calls
    // first. True when entries were removed. waitForPrune: tests.
    void startPrune(bool force = false);
    bool collectPruned();
    void waitForPrune();

    void setFallbackFile(const QString &file);
    QString fallbackFile() const { return m_file; }
    // The default location (see above).
    static QString defaultFallbackFile();

    // The style of a folder now: the fallback entry if there is one, else the attribute; empty for anything else
    // (no such folder, a link, a file, an unreadable attribute).
    FolderStyleLogic::Style read(const QString &path) const;

    struct Result {
        bool ok = false;
        bool fellBack = false; // stored in the fallback store because the attribute can't be written
        bool changed = false;
        QString error; // a sentence fragment with the system's reason, when !ok
    };
    // Sets the folder's look to exactly `style` (empty = reset: attribute removed, entry dropped).
    Result write(const QString &path, const FolderStyleLogic::Style &style);

    // Files moved or renamed a folder: the entry of `from` (and of the folders under it) now belongs to `to`. True when
    // the store changed. Moves done outside Files are not seen: those entries are pruned at the next write.
    bool moveEntries(const QString &from, const QString &to);
    // Files created a folder at `path`: an old entry for that path must not apply to it.
    bool dropEntry(const QString &path);

    // Reads the fallback store again when its file changed on disk (another process). True when the entries changed.
    bool reload();
    int fallbackCount() const;
    // Whether the fallback store exists but could not be parsed (writes needing it are refused).
    bool fallbackBroken() const;

private:
    void ensureLoaded() const;
    bool loadFile() const;
    bool saveFile(QString *error);
    struct PruneJob;
    static QString keyFor(const QString &path);

    QString m_file;
    mutable bool m_loaded = false;
    mutable bool m_broken = false;
    mutable qint64 m_stamp = 0; // mtime and size of the file when loaded
    mutable qint64 m_serial = 0;
    mutable QHash<QString, FolderStyleLogic::Style> m_entries;
    std::shared_ptr<PruneJob> m_job;
    std::unique_ptr<QThread> m_thread;
    QElapsedTimer m_lastPrune;
    bool m_haveMounts = false;
    Mounts m_mounts;
    QStringList m_touched; // keys written, moved or dropped while a pruning runs: it may not remove them
};
