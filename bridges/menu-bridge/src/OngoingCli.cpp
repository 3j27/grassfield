// SPDX-License-Identifier: MIT
// grassfield-ongoing: an ongoing activity in the menu bar for a script (ADR-0052). It stays connected while the activity
// lasts (the host ends an activity when its publisher leaves the bus) and publishes as the application scope it runs in
// (a script started from Terminal shows as Terminal): there is no option to name another application.
//
//   grassfield-ongoing run [--kind K] --title T [--subtitle S] -- COMMAND [ARG...]
//       indeterminate while COMMAND runs; its Stop button sends COMMAND SIGTERM; exits with COMMAND's status
//   grassfield-ongoing progress [--kind K] --title T [--subtitle S]
//       zenity's --progress protocol on stdin: a number is the percent (0-100), "# text" the subtitle; ends at end of input;
//       exits 1 when the user chose Stop
//   grassfield-ongoing timer --title T --seconds N [--subtitle S]
//       a countdown of N seconds (1 to 86400); exits 1 when the user chose Stop
// Exit status 2: usage error. Kinds: timer, transfer, recording, install, call, progress (the default).

#include "ongoing.h"
#include "translationloader.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFile>
#include <QSocketNotifier>
#include <QStringList>
#include <QTimer>

#include <csignal>
#include <cstring>
#include <memory>
#include <spawn.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <vector>
#include <cstdio>
#include <unistd.h>

using grassfield::apps::OngoingActivity;
using grassfield::apps::OngoingPublisher;

extern char** environ;

namespace {
    int usage() {
        std::fprintf(stderr, "usage: grassfield-ongoing run [--kind K] --title T [--subtitle S] -- COMMAND [ARG...]\n"
                             "       grassfield-ongoing progress [--kind K] --title T [--subtitle S]   (stdin: percent, or \"# text\")\n"
                             "       grassfield-ongoing timer --title T --seconds N [--subtitle S]\n");
        return 2;
    }

    const QStringList kKinds = {QStringLiteral("timer"), QStringLiteral("transfer"), QStringLiteral("recording"), QStringLiteral("install"), QStringLiteral("call"),
                                QStringLiteral("progress")};
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-ongoing"));
    grassfield::i18n::install(grassfield::i18n::systemLanguage());

    QStringList args = QCoreApplication::arguments().mid(1);
    if (args.isEmpty() || args.first() == QLatin1String("--help"))
        return usage();
    const QString mode = args.takeFirst();
    if (mode != QLatin1String("run") && mode != QLatin1String("progress") && mode != QLatin1String("timer"))
        return usage();

    OngoingActivity activity;
    activity.kind = mode == QLatin1String("timer") ? QStringLiteral("timer") : QStringLiteral("progress");
    qint64      seconds = 0;
    QStringList command;
    while (!args.isEmpty()) {
        const QString a = args.takeFirst();
        if (a == QLatin1String("--")) {
            command = args;
            break;
        }
        if (args.isEmpty())
            return usage();
        const QString value = args.takeFirst();
        if (a == QLatin1String("--title"))
            activity.title = value;
        else if (a == QLatin1String("--subtitle"))
            activity.subtitle = value;
        else if (a == QLatin1String("--kind") && kKinds.contains(value))
            activity.kind = value;
        else if (a == QLatin1String("--seconds") && mode == QLatin1String("timer"))
            seconds = value.toLongLong();
        else
            return usage();
    }
    if (activity.title.trimmed().isEmpty())
        return usage();
    if (mode == QLatin1String("run") && command.isEmpty())
        return usage();
    if (mode != QLatin1String("run") && !command.isEmpty())
        return usage();
    if (mode == QLatin1String("timer") && (seconds < 1 || seconds > 86400))
        return usage();
    if (activity.kind == QLatin1String("timer") && mode != QLatin1String("timer"))
        activity.started = QDateTime::currentMSecsSinceEpoch(); // a timer shows a time: the elapsed one
    activity.actions = {{QStringLiteral("stop"), QCoreApplication::translate("OngoingCli", "Stop")}};

    // One activity per process: two scripts of the same terminal do not take each other's.
    const QString    id = QStringLiteral("cli-%1").arg(::getpid());
    OngoingPublisher publisher;
    int              status = 0;

    if (mode == QLatin1String("run")) {
        // posix_spawnp rather than QProcess: the shell's convention for the status (128 + the signal that ended the command)
        // needs the wait status itself, which QProcess does not give for a crash. stdin, stdout and stderr are inherited.
        std::vector<QByteArray> bytes;
        for (const QString& a : command)
            bytes.push_back(QFile::encodeName(a));
        std::vector<char*> argv;
        for (QByteArray& b : bytes)
            argv.push_back(b.data());
        argv.push_back(nullptr);
        pid_t     pid = 0;
        const int rc  = ::posix_spawnp(&pid, argv.front(), nullptr, nullptr, argv.data(), environ);
        if (rc != 0) {
            std::fprintf(stderr, "grassfield-ongoing: cannot start %s: %s\n", argv.front(), std::strerror(rc));
            return 127;
        }
        bool done = false;
        auto reap = [pid, &status, &done]() {
            int st = 0;
            if (done || ::waitpid(pid, &st, WNOHANG) != pid)
                return;
            done   = true;
            status = WIFEXITED(st) ? WEXITSTATUS(st) : (WIFSIGNALED(st) ? 128 + WTERMSIG(st) : 1);
            QCoreApplication::quit();
        };
        // A pidfd becomes readable when the command exits; without one (a kernel before 5.3) a slow poll.
        const int                        pidfd = static_cast<int>(::syscall(SYS_pidfd_open, pid, 0));
        std::unique_ptr<QSocketNotifier> exited;
        QTimer                           poll;
        if (pidfd >= 0) {
            exited = std::make_unique<QSocketNotifier>(pidfd, QSocketNotifier::Read);
            QObject::connect(exited.get(), &QSocketNotifier::activated, &app, reap);
        } else {
            QObject::connect(&poll, &QTimer::timeout, &app, reap);
            poll.start(200);
        }
        // Stop: through the pidfd when there is one (it names this command, never a later process that reused its pid), and
        // never once the command was reaped.
        QObject::connect(&publisher, &OngoingPublisher::actionInvoked, &app, [pid, pidfd, &done](const QString&, const QString& action) {
            if (action != QLatin1String("stop") || done)
                return;
            if (pidfd >= 0)
                ::syscall(SYS_pidfd_send_signal, pidfd, SIGTERM, nullptr, 0);
            else
                ::kill(pid, SIGTERM);
        });
        publisher.set(id, activity);
        reap(); // it may be done already
        if (!done)
            QCoreApplication::exec();
        if (pidfd >= 0)
            ::close(pidfd);
        return status;
    }

    QObject::connect(&publisher, &OngoingPublisher::actionInvoked, &app, [&status](const QString&, const QString& action) {
        if (action == QLatin1String("stop")) {
            status = 1;
            QCoreApplication::quit();
        }
    });

    if (mode == QLatin1String("timer")) {
        activity.ends = QDateTime::currentMSecsSinceEpoch() + seconds * 1000;
        publisher.set(id, activity);
        QTimer::singleShot(seconds * 1000, &app, &QCoreApplication::quit);
        QCoreApplication::exec();
        return status;
    }

    // progress: zenity's protocol on stdin.
    publisher.set(id, activity);
    QByteArray      pending;
    QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&input, &QSocketNotifier::activated, &app, [&] {
        char          buf[4096];
        const ssize_t n = ::read(STDIN_FILENO, buf, sizeof(buf));
        if (n <= 0) {
            input.setEnabled(false);
            QCoreApplication::quit(); // end of input: the activity ends with the process
            return;
        }
        pending.append(buf, n);
        if (pending.size() > 64 * 1024)
            pending = pending.right(4096);
        qsizetype nl = 0;
        while ((nl = pending.indexOf('\n')) >= 0) {
            const QString line = QString::fromUtf8(pending.left(nl)).trimmed();
            pending.remove(0, nl + 1);
            if (line.startsWith(u'#')) {
                activity.subtitle = line.mid(1).trimmed();
            } else {
                bool         ok      = false;
                const double percent = line.toDouble(&ok);
                if (ok)
                    activity.progress = qBound(0.0, percent / 100.0, 1.0);
            }
        }
        publisher.set(id, activity);
    });
    QCoreApplication::exec();
    return status;
}
