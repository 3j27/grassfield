#pragma once

// Who asks (ADR-0035 D-9, "Not a phishing tool"): the requester a secret sheet shows in its fixed top row is resolved by
// the bridge from the bus's credentials of the caller, never from the caller's text. Linux only.
//
// GetConnectionCredentials hands out the caller's pidfd (ProcessFD; dbus-broker 37 and dbus-daemon 1.16 have it). Its PID
// comes from /proc/self/fdinfo/<pidfd>, then /proc/<pid>/exe is read (its target's name, and the file itself through an
// O_PATH open), then the pidfd is checked again: when the process still runs, the PID was not reused between. The
// executable is trusted only when its absolute path names that same file now, and the file and every directory above it
// belong to root and are not writable by group or others. A trusted executable is then:
// - "keyring" for /usr/bin/gnome-keyring-daemon, "gnupg" for /usr/bin/pinentry-gnome3 and /usr/bin/gpg-agent (they ask on
//   another program's behalf: the caller's text names that program, under the fixed row);
// - "app" with a desktop entry's name and icon when exactly one entry of /usr/share/applications (a root-owned regular
//   file) runs exactly that executable: its Exec line is the program and field codes only, so an interpreter, a wrapper or
//   a launcher with arguments never lends its entry to whatever it runs;
// - anything else, and every failure on the way (no ProcessFD, the process gone, another user, an executable in the home
//   or deleted), is "unidentified" with the executable's path when it is known.
// The pure parts take the owner and the top of the tree as parameters, so the tests run them on temporary trees.

#include "Protocol.h"

#include <QByteArray>
#include <QList>
#include <QString>

#include <optional>
#include <sys/types.h>

namespace gf::prompter {

    struct FileId {
        bool  valid = false;
        dev_t dev   = 0;
        ino_t ino   = 0;
        bool  operator==(const FileId& o) const {
            return valid && o.valid && dev == o.dev && ino == o.ino;
        }
    };

    // stat(2) of `path` (symlinks followed).
    FileId fileIdOf(const QString& path);

    // An absolute path without "." or ".." components to a regular file owned by `owner` and not writable by group or
    // others, whose every directory from its parent up to `top` (both included) is a real directory (lstat: a symlink
    // anywhere is refused) owned by `owner` and not writable by group or others.
    bool trustedPath(const QString& path, uid_t owner = 0, const QString& top = QStringLiteral("/"));

    struct DesktopEntry {
        QString id; // the file name
        QString name;
        QString icon;
        QString exec;
        bool    application = false; // Type=Application
        bool    hidden      = false; // Hidden=true
    };

    // The [Desktop Entry] group of a desktop entry file: the unlocalized Name and Icon, Exec, Type and Hidden (escapes
    // \s \n \t \r \\ decoded).
    DesktopEntry parseDesktopEntry(const QByteArray& text);

    // The program of an Exec line when the line is that program followed by field codes only (%f %F %u %U %i %c %k); empty
    // otherwise (any other argument, an environment assignment, "env", a quoting error).
    QString execProgramOnly(const QString& exec);

    // Where a bare program name of an Exec line is looked for.
    inline const QStringList& programDirectories() {
        static const QStringList dirs{QStringLiteral("/usr/bin"), QStringLiteral("/usr/local/bin")};
        return dirs;
    }

    // The one desktop entry of `dir` that runs the file `exe` (see the header); nothing when none or several do. Only
    // regular files named *.desktop directly in `dir` that are trusted (owner, top) are read, at most 4096 of them, each at
    // most 64 KiB; `programDirs` resolve bare program names.
    std::optional<DesktopEntry> desktopEntryFor(const FileId& exe, const QString& dir, const QStringList& programDirs, uid_t owner,
                                                const QString& top);

    struct KnownCaller {
        QString path;
        QString role;
    };

    // gnome-keyring-daemon -> keyring; pinentry-gnome3 and gpg-agent -> gnupg.
    const QList<KnownCaller>& knownCallers();

    // The role of `exe` among `known` (the same file, by device and inode, as a trusted path of the list); empty when none.
    QString knownRole(const FileId& exe, const QList<KnownCaller>& known, uid_t owner, const QString& top);

    // What the kernel says about the caller.
    struct ExeFacts {
        QString path;          // /proc/<pid>/exe's target; empty when unreadable
        FileId  file;          // the file /proc/<pid>/exe leads to
        bool    alive = false; // the pidfd still ran after both reads
        bool    sameUser = false; // the bus's UnixUserID is this user
    };

    struct Where {
        QString            applications = QStringLiteral("/usr/share/applications");
        QStringList        programDirs  = programDirectories();
        QList<KnownCaller> known        = knownCallers();
        uid_t              owner        = 0;
        QString            top          = QStringLiteral("/");
    };

    // The requester for those facts (texts flattened and capped).
    RequesterView requesterFor(const ExeFacts& facts, const Where& where = Where());

    // The facts behind a pidfd (sameUser is left false: the caller sets it from the bus).
    ExeFacts exeFactsOfPidfd(int pidfd);

} // namespace gf::prompter
