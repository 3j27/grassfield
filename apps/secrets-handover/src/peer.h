// Who owns a bus name: the executable of the process behind it, read through the pidfd the bus hands out (ProcessFD of
// GetConnectionCredentials), never through a bare PID (ADR-0035 D-9, D-12). Linux only.
#pragma once

#include <QDBusConnection>
#include <QString>

#include <sys/types.h>

namespace grassfield::handover {

struct Peer {
    QString owner;   // the unique name (":1.42"), empty when nobody owns the name
    QString exe;     // the owner's executable as /proc/<pid>/exe names it ("… (deleted)" once replaced); empty when unknown
    uint uid = 0;    // the owner's user, as the bus reports it
    pid_t pid = 0;
    int pidfd = -1;  // kept open while the peer is used: signalling through it can never reach a reused PID
    // The executable file itself (fstat through /proc/<pid>/exe): compared by inode, never by its name alone.
    bool hasFile = false;
    dev_t fileDev = 0;
    ino_t fileIno = 0;
    uid_t fileUid = 0;
    mode_t fileMode = 0;
    nlink_t fileLinks = 0;
};

// The owner of `name` now, without starting it. exe stays empty when the bus gives no ProcessFD, the process is gone, or its
// /proc/<pid>/exe cannot be read (another user, a non-dumpable process, or this process in a user namespace of its own: a
// systemd user unit with ProtectSystem=, PrivateTmp= and the like gets PrivateUsers=self, so its unit uses none of them); the
// executable is read, then the pidfd is checked again, so a reused PID is never taken for the peer. The caller closes it.
Peer identify(const QDBusConnection &bus, const QString &name);
void close(Peer &peer);

// The process behind the pidfd still runs (a pidfd becomes readable when its process exits).
bool alive(int pidfd);

// An absolute path to a regular file owned by root and not writable by its group or others, in directories that are all
// owned by root and not writable by their group or others: an executable the user cannot have replaced.
bool trustedExecutable(const QString &path);

// The peer runs `expected` (a trusted executable: the same file, by device and inode) as the current user, and was alive
// after its executable was read.
bool is(const Peer &peer, const QString &expected);

// `is`, or the peer runs a root-owned `expected` that has since been replaced (a package upgrade during an earlier session:
// "/usr/bin/ksecretd (deleted)", no link left). Only to ask such a leftover to quit; never to read or write a secret.
bool ranFrom(const Peer &peer, const QString &expected);

} // namespace grassfield::handover
