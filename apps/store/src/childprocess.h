// The child processes the Store owns for reading (ADR-0037 f): pacman queries, gpgv, pacman-key --verify, bsdtar. An
// argument vector, never a shell; LC_ALL=C and a fixed PATH; stdin from /dev/null; its own process group; output capped
// (8 MiB by default: more, and the group is stopped); stopped after the deadline (20 s by default) with SIGTERM, then SIGKILL
// 5 s later; and it dies with the Store (PDEATHSIG). None of them writes outside the paths it is given.
#pragma once

#include <QByteArray>
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>

namespace grassfield::store {

struct ChildResult {
    bool started = false;
    bool timedOut = false;
    bool overflow = false; // more output than the cap: stopped, and the output is not used
    int exitCode = -1;     // -1 unless it exited normally
    QByteArray out;
    QByteArray err; // at most 64 KiB, for a message
    bool ok() const { return started && !timedOut && !overflow && exitCode == 0; }
};

struct ChildOptions {
    int timeoutMs = 20000;
    qint64 maxOut = 8 * 1024 * 1024;
    QProcessEnvironment extraEnv; // added to the fixed environment (GNUPGHOME for gpgv, for example)
};

ChildResult runChild(const QString &program, const QStringList &args, const ChildOptions &options = {});

} // namespace grassfield::store
