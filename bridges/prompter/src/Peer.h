#pragma once

// The shell's socket: where it lives and who may connect (ADR-0035 D-9). Linux only. The parsing and the decisions are pure
// and unit-tested in tests/unit/prompter/; checkSocketPeer reads the kernel.
//
// A peer is accepted when SO_PEERCRED says it runs as this user and its cgroup is the expected unit's
// (grassfield-shell.service by default, from --peer-unit in the systemd unit). The cgroup is read race-free: the kernel
// hands out a pidfd of the peer (SO_PEERPIDFD, Linux 6.5), the PID comes from that pidfd's fdinfo, /proc/<pid>/cgroup is
// read, then the pidfd is checked again: when the process still runs, the PID was not reused between. On an older kernel
// the PID of SO_PEERCRED is read instead, and a peer that exits and whose PID is reused by a process of the expected unit
// in between would pass (the residual race, documented in the spec).

#include <QByteArray>
#include <QString>

#include <sys/types.h>

namespace gf::prompter {

    // The path of the unified (cgroup v2) hierarchy in the text of /proc/<pid>/cgroup: the "0::<path>" line; empty when
    // there is none.
    QString unifiedCgroupPath(const QByteArray& procCgroup);

    // `path` is the cgroup of the unit `unit`: its last component is exactly `unit` and, when `requireUserManager`, an
    // earlier component is exactly "user@<uid>.service" (the unit runs under this user's own systemd manager). A removed
    // cgroup (" (deleted)") or a relative path never matches.
    bool cgroupIsUnit(const QString& path, const QString& unit, uid_t uid, bool requireUserManager);

    // A --peer-unit value: in a session a systemd service name ("<name>.service", "<name>@<instance>.service"; letters,
    // digits and ":_.\-" only); in a development run any single path component (a container has no user manager, and the
    // tests name their own cgroup).
    bool validPeerUnit(const QString& unit, bool dev);

    // The PID of the "Pid:" line of a pidfd's /proc/self/fdinfo text: > 0, -1 when the process has exited, 0 when the
    // line is missing, not a number, or the process is in another PID namespace.
    qint64 pidFromFdinfo(const QByteArray& fdinfo);

    // The process behind the pidfd still runs (a pidfd turns readable when its process exits).
    bool pidfdAlive(int pidfd);

    // The PID behind `pidfd` (pidFromFdinfo of /proc/self/fdinfo/<pidfd>).
    qint64 pidOfPidfd(int pidfd);

    struct PeerCheck {
        bool    accepted = false;
        QString reason;   // why it was refused, for the journal
        qint64  pid      = 0;
        QString cgroup;
        bool    raceFree = false; // the cgroup was read through SO_PEERPIDFD
    };

    // The decision for the connected socket `fd`.
    PeerCheck checkSocketPeer(int fd, uid_t uid, const QString& unit, bool requireUserManager);

    // --- the socket's place ------------------------------------------------------------------------------------------

    // <runtimeDir>/grassfield/prompter.sock, or `overridePath` when set; empty when neither is an absolute path.
    QString socketPath(const QString& overridePath, const QString& runtimeDir);

    // An AF_UNIX path fits sockaddr_un.sun_path with its terminating NUL.
    bool fitsSocketPath(const QString& path);

    // The socket's directory: created with mode 0700 when missing (its parent must exist, be a real directory of this
    // user and not be writable by group or others); an existing one must be a real directory (lstat: never a symlink)
    // owned by this user, and its group and other bits are removed. Returns an error text, empty on success.
    QString prepareSocketDirectory(const QString& socketPath);

} // namespace gf::prompter
