// Shared by the Grassfield apps (R5: one copy). An application one of the apps starts (Files and Glance -> Preview,
// Preview -> the full viewer) runs in a scope of its own through uwsm's app launcher, like the applications the shell
// starts (shell/services/Apps.qml scoped): without it the child stays in the unit of the app that started it and
// closes with it. Only in a real session (GRASSFIELD_SESSION=1, never GRASSFIELD_DEV=1) and only when uwsm-app is on
// the PATH (looked up synchronously: no race at start-up).
#pragma once

#include <QProcess>
#include <QStandardPaths>
#include <QString>
#include <QStringList>

namespace grassfield::apps {

inline bool scopedLaunch()
{
    return qEnvironmentVariable("GRASSFIELD_SESSION") == QLatin1String("1")
        && qEnvironmentVariable("GRASSFIELD_DEV") != QLatin1String("1")
        && !QStandardPaths::findExecutable(QStringLiteral("uwsm-app")).isEmpty();
}

// program + args of an application start: `uwsm-app -- program args` in a real session, unchanged otherwise.
inline QStringList scopedCommand(const QString &program, const QStringList &args, bool scoped)
{
    if (!scoped)
        return QStringList{program} + args;
    return QStringList{QStringLiteral("uwsm-app"), QStringLiteral("--"), program} + args;
}

// Starts an application detached (scoped in a real session); false when it could not be started.
inline bool startApplication(const QString &program, const QStringList &args)
{
    QStringList command = scopedCommand(program, args, scopedLaunch());
    const QString first = command.takeFirst();
    return QProcess::startDetached(first, command);
}

} // namespace grassfield::apps
