// Who owns a bus name: the executable of the process behind it, read through the pidfd the bus hands out (ProcessFD of
// GetConnectionCredentials), never through a bare PID (ADR-0035 D-9, D-12). Linux only.
#pragma once

#include <QDBusConnection>
#include <QString>

#include <sys/types.h>

namespace grassfield::handover {

struct Peer {
    QString owner;   // the unique name (":1.42"), empty when nobody owns the name
    QString exe;     // the owner's executable, empty when it cannot be known for sure
    uint uid = 0;    // the owner's user, as the bus reports it
    pid_t pid = 0;
    int pidfd = -1;  // kept open while the peer is used: signalling through it can never reach a reused PID
};

// The owner of `name` now, without starting it. exe stays empty when the bus gives no ProcessFD, the process is gone, or its
// executable was replaced or deleted. The caller closes the peer.
Peer identify(const QDBusConnection &bus, const QString &name);
void close(Peer &peer);

// The process behind the pidfd still runs (a pidfd becomes readable when its process exits).
bool alive(int pidfd);

// An absolute path to a regular file owned by root and not writable by its group or others, in directories that are all
// owned by root and not writable by their group or others: an executable the user cannot have replaced.
bool trustedExecutable(const QString &path);

// The peer runs `expected` (a trusted executable) as the current user, and was alive after its executable was read.
bool is(const Peer &peer, const QString &expected);

} // namespace grassfield::handover
