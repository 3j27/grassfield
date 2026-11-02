#include "childprocess.h"

#include <QElapsedTimer>
#include <QProcess>

#include <csignal>
#include <sys/prctl.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr qint64 kMaxErr = 64 * 1024;

void signalGroup(qint64 pid, int sig)
{
    if (pid > 0)
        ::kill(-pid_t(pid), sig);
}

} // namespace

ChildResult runChild(const QString &program, const QStringList &args, const ChildOptions &options)
{
    ChildResult r;
    const auto cancelled = [&options] { return options.cancel && options.cancel->load(); };
    if (cancelled()) {
        r.cancelled = true;
        return r;
    }
    QProcess p;
    p.setProgram(program);
    p.setArguments(args);
    QProcessEnvironment env;
    env.insert(QStringLiteral("PATH"), QStringLiteral("/usr/bin:/bin"));
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    for (const QString &key : options.extraEnv.keys())
        env.insert(key, options.extraEnv.value(key));
    p.setProcessEnvironment(env);
    p.setStandardInputFile(QProcess::nullDevice());
    p.setChildProcessModifier([] {
        ::setpgid(0, 0); // its own group: the deadline stops what it started too
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
    });
    p.start();
    if (!p.waitForStarted(5000))
        return r;
    r.started = true;
    const qint64 pid = p.processId();
    QElapsedTimer clock;
    clock.start();
    auto drain = [&] {
        r.out += p.readAllStandardOutput();
        const QByteArray err = p.readAllStandardError();
        if (r.err.size() < kMaxErr)
            r.err += err.left(kMaxErr - r.err.size());
        if (r.out.size() > options.maxOut)
            r.overflow = true;
    };
    while (!p.waitForFinished(100)) {
        drain();
        r.cancelled = cancelled();
        if (r.overflow || r.cancelled || clock.elapsed() > options.timeoutMs) {
            r.timedOut = !r.overflow && !r.cancelled;
            signalGroup(pid, SIGTERM);
            if (!p.waitForFinished(5000)) {
                signalGroup(pid, SIGKILL);
                p.waitForFinished(2000);
            }
            r.out.clear();
            return r;
        }
    }
    drain();
    // No signal after it ended: its group id could already name someone else's group.
    if (r.overflow) {
        r.out.clear();
        return r;
    }
    if (p.exitStatus() == QProcess::NormalExit)
        r.exitCode = p.exitCode();
    return r;
}

} // namespace grassfield::store
