#pragma once

#include "folderstylelogic.h"

#include <QHash>
#include <QString>

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
// An entry wins over the attribute (it is the user's explicit choice on this machine). A store that cannot be parsed is
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
    explicit FolderStyleStore(const QString &fallbackFile = QString());

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

    // Reads the fallback store again when its file changed on disk (another process). True when the entries changed.
    bool reload();
    int fallbackCount() const;
    // Whether the fallback store exists but could not be parsed (writes needing it are refused).
    bool fallbackBroken() const;

private:
    void ensureLoaded() const;
    bool loadFile() const;
    bool saveFile(QString *error);
    static QString keyFor(const QString &path);

    QString m_file;
    mutable bool m_loaded = false;
    mutable bool m_broken = false;
    mutable qint64 m_stamp = 0; // mtime and size of the file when loaded
    mutable qint64 m_serial = 0;
    mutable QHash<QString, FolderStyleLogic::Style> m_entries;
};
