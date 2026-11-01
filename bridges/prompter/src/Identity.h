#pragma once

// Who asks (ADR-0035 D-9, "Not a phishing tool"): the requester a secret sheet shows in its fixed top row is resolved by
// the bridge from the bus's credentials of the caller, never from the caller's text. Linux only.
//
// GetConnectionCredentials hands out the caller's pidfd (ProcessFD; dbus-broker 37 and dbus-daemon 1.16 have it). Its PID
// comes from /proc/self/fdinfo/<pidfd>, then /proc/<pid>/exe is read (its target's name, and the file itself through an
// O_PATH open), then the pidfd is checked again: when the process still runs, the PID was not reused between. The
// executable is trusted only when its absolute path names that same file now, and the file and every directory above it
// belong to root and are not writable by group or others, and the process is not being traced (a tracer can run any code
// in it). A trusted executable is then:
// - "keyring" for /usr/bin/gnome-keyring-daemon, "gnupg" for /usr/bin/pinentry-gnome3 and /usr/bin/gpg-agent, "ssh" for
//   /usr/lib/gcr-ssh-agent: they ask on another program's behalf, and any program of the user can make them ask with
//   text of its own (gpg-connect-agent, running pinentry-gnome3, ssh-add), so the row names the program that asks, never
//   a guarantee about the text under it, which the shell shows as another program's unverified words; "disk" for
//   /usr/lib/grassfield/grassfield-askpass, udiskie's password command (step 9c), which any program can run with a disk
//   name of its own, likewise; "kio" for /usr/lib/kf6/kioworker, KIO's worker executable (step 9e), which runs whatever worker
//   plugin its command line names, likewise;
// - "app" with a desktop entry's name and icon when exactly one entry of /usr/share/applications (a root-owned regular
//   file) runs exactly that executable: its Exec line is the program and field codes only, so an interpreter, a wrapper or
//   a launcher with arguments never lends its entry to whatever it runs; and every file mapped executable in the process
//   is trusted as well (no LD_PRELOAD or LD_LIBRARY_PATH code, no plugin from the user's files, nothing replaced since it
//   was loaded): a trusted path whose file, by device and inode, is the one the mapping names, in a process that shares
//   the bridge's mount and user namespaces (a user namespace lets a process bind-mount its own file over a trusted path:
//   counter-review of step 9a, MINOR-C);
// - anything else, and every failure on the way (no ProcessFD, the process gone, another user, an executable in the home
//   or deleted, a traced process), is "unidentified" with the executable's path when it is known.
// What this cannot see (security review of step 9a, MINOR-2, decision 9-14): the row names the program whose process
// opened the bus connection, not proof of whose code speaks on it. A process can connect, fork, and exec a trusted program
// while its child keeps using the connection; an ancestor can ptrace a trusted program, change its code and detach; a
// trusted app can run the user's code through its own scripting (emacs --batch -l, nvim -l), mapping no untrusted file.
// The pure parts take the owner and the top of the tree as parameters, so the tests run them on temporary trees.

#include "Protocol.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QPair>
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

    // gnome-keyring-daemon -> keyring; pinentry-gnome3 and gpg-agent -> gnupg; gcr-ssh-agent -> ssh; grassfield-askpass -> disk;
    // kioworker -> kio.
    const QList<KnownCaller>& knownCallers();

    // A file mapped executable: its path and the device (major:minor) and inode /proc/<pid>/maps gives for it.
    struct CodeMapping {
        QString path;
        quint32 major = 0;
        quint32 minor = 0;
        quint64 inode = 0;
        bool    operator==(const CodeMapping& o) const {
            return path == o.path && major == o.major && minor == o.minor && inode == o.inode;
        }
    };

    // The files mapped executable in a process, from the text of /proc/<pid>/maps (unique by path, device and inode, in
    // order; pseudo mappings such as [vdso] and anonymous ones left out); *ok false when a line cannot be read.
    QList<CodeMapping> executableMappings(const QByteArray& maps, bool* ok);

    // Mount id -> device (major, minor) of the text of /proc/self/mountinfo: the device a mapping of a file of that mount
    // shows in /proc/<pid>/maps (the superblock's; on btrfs, stat's st_dev is the subvolume's instead).
    QHash<quint64, QPair<quint32, quint32>> mountDevices(const QByteArray& mountinfo);

    // What /proc/<pid>/maps would show for the file at `path` now, in the bridge's mount namespace: statx's inode, and its
    // mount's device looked up in `devices`. inode 0 when it cannot be had.
    CodeMapping fileMapping(const QString& path, const QHash<quint64, QPair<quint32, quint32>>& devices);

    // The "TracerPid:" of /proc/<pid>/status: 0 when not traced, -1 when the line is missing or not a number.
    qint64 tracerPid(const QByteArray& status);

    // The role of `exe` among `known` (the same file, by device and inode, as a trusted path of the list); empty when none.
    QString knownRole(const FileId& exe, const QList<KnownCaller>& known, uid_t owner, const QString& top);

    // What the kernel says about the caller.
    struct ExeFacts {
        QString path;          // /proc/<pid>/exe's target; empty when unreadable
        FileId  file;          // the file /proc/<pid>/exe leads to
        bool    alive = false; // the pidfd still ran after every read
        bool    sameUser = false; // the bus's UnixUserID is this user
        bool    traced = true;    // TracerPid is not 0, or unknown
        bool    sameNamespaces = false; // its mount and user namespaces are the bridge's
        bool    codeKnown = false;  // /proc/<pid>/maps was read whole
        QList<CodeMapping> code;    // the files mapped executable (executableMappings)
    };

    // mountDevices of /proc/self/mountinfo.
    QHash<quint64, QPair<quint32, quint32>> selfMountDevices();

    struct Where {
        QString            applications = QStringLiteral("/usr/share/applications");
        QStringList        programDirs  = programDirectories();
        QList<KnownCaller> known        = knownCallers();
        uid_t              owner        = 0;
        QString            top          = QStringLiteral("/");
        // The bridge's mounts (/proc/self/mountinfo), read when the requester is resolved.
        QHash<quint64, QPair<quint32, quint32>> devices = selfMountDevices();
    };

    // The requester for those facts (texts flattened and capped).
    RequesterView requesterFor(const ExeFacts& facts, const Where& where = Where());

    // The facts behind a pidfd (sameUser is left false: the caller sets it from the bus). `withCode` false reads the
    // executable only (for a journal line), not its namespaces, tracer and mappings.
    ExeFacts exeFactsOfPidfd(int pidfd, bool withCode = true);

} // namespace gf::prompter
