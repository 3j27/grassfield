// The child processes the Store owns for reading (ADR-0037 f): pacman queries, gpgv, gpg on a copy of pacman's keyring,
// bsdtar. An
// argument vector, never a shell; LC_ALL=C and a fixed PATH; stdin from /dev/null; its own process group; output capped
// (8 MiB by default: more, and the group is stopped); stopped after the deadline (20 s by default) with SIGTERM, then SIGKILL
// 5 s later, or as soon as its cancel flag is set (the Store quitting); and it dies with the Store (PDEATHSIG). None of them
// writes outside the paths it is given.
#pragma once

#include <QByteArray>
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>

#include <atomic>
#include <memory>

namespace grassfield::store {

struct ChildResult {
    bool started = false;
    bool timedOut = false;
    bool overflow = false; // more output than the cap: stopped, and the output is not used
    bool cancelled = false; // its cancel flag was set: stopped (or not started), and the output is not used
    int exitCode = -1;     // -1 unless it exited normally
    QByteArray out;
    QByteArray err; // at most 64 KiB, for a message
    bool ok() const { return started && !timedOut && !overflow && !cancelled && exitCode == 0; }
};

struct ChildOptions {
    int timeoutMs = 20000;
    qint64 maxOut = 8 * 1024 * 1024;
    QProcessEnvironment extraEnv; // added to the fixed environment (GNUPGHOME for gpgv, for example)
    std::shared_ptr<const std::atomic_bool> cancel; // set: the child is stopped within 100 ms (the Store quits)
};

ChildResult runChild(const QString &program, const QStringList &args, const ChildOptions &options = {});

} // namespace grassfield::store
