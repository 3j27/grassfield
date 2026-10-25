// The run-mode rule of the Grassfield apps (ADR-0019, GF-089, slice M6): the C++ side of shell/lib/RunMode.js, held to the
// same answers by tests/fixtures/run-mode-vectors.json (tests/unit/files/tst_runmode.cpp). The only reader of
// GRASSFIELD_DEV, GRASSFIELD_SESSION, GRASSFIELD_CONFIG_HOME and GRASSFIELD_STATE_HOME in apps/ (the dev plumbing variables
// of ADR-0019 go through devPlumbing()).
//
// dev = GRASSFIELD_DEV exactly "1" AND GRASSFIELD_SESSION not "1". "dev" means both "test hooks allowed" and "never act on
// the owner's machine". The packaged session sets GRASSFIELD_SESSION=1, so a GRASSFIELD_DEV=1 that leaked into it changes
// nothing; the nested dev session never sets it (scripts/dev/devenv.sh unsets an inherited one).
//
// The functions of the first group are pure (they take the raw values of the variables, "" when unset) so the vectors run
// without touching the process environment; the second group reads it.
#pragma once

#include <QDir>
#include <QString>
#include <QStringList>

namespace grassfield::apps::runmode {

inline bool dev(const QString &devValue, const QString &sessionValue)
{
    return devValue == QLatin1String("1") && sessionValue != QLatin1String("1");
}

// A packaged session: GRASSFIELD_SESSION exactly "1" (independent of dev).
inline bool session(const QString &sessionValue)
{
    return sessionValue == QLatin1String("1");
}

// A dev-plumbing variable (ADR-0019 table): its value in dev, "" otherwise.
inline QString devPlumbing(const QString &devValue, const QString &sessionValue, const QString &value)
{
    return dev(devValue, sessionValue) ? value : QString();
}

// $GRASSFIELD_CONFIG_HOME wins (always honoured), else $XDG_CONFIG_HOME/grassfield, else <home>/.config/grassfield.
// An empty value counts as unset.
inline QString configDir(const QString &configHome, const QString &xdgConfigHome, const QString &home)
{
    if (!configHome.isEmpty())
        return configHome;
    return (xdgConfigHome.isEmpty() ? home + QStringLiteral("/.config") : xdgConfigHome) + QStringLiteral("/grassfield");
}

// $GRASSFIELD_STATE_HOME wins (always honoured), else $XDG_STATE_HOME/grassfield, else <home>/.local/state/grassfield.
inline QString stateDir(const QString &stateHome, const QString &xdgStateHome, const QString &home)
{
    if (!stateHome.isEmpty())
        return stateHome;
    return (xdgStateHome.isEmpty() ? home + QStringLiteral("/.local/state") : xdgStateHome) + QStringLiteral("/grassfield");
}

// The directory of the running shell for `qs ipc -p`, never by name (`-c` would also search the user-writable
// ~/.config/quickshell, GF-115). In dev: GRASSFIELD_SHELL_DIR (the repository's shell), or "" when it is not set: a dev
// session never drives the installed shell, which may be the owner's real one (a debug build never drives the shipped
// app). Outside dev: the installed shell.
inline QString shellDir(const QString &devValue, const QString &sessionValue, const QString &shellDirValue)
{
    if (dev(devValue, sessionValue))
        return shellDirValue;
    return QStringLiteral("/usr/share/grassfield/shell");
}

// --- the process environment ---------------------------------------------------------------------------------------

inline bool dev()
{
    return dev(qEnvironmentVariable("GRASSFIELD_DEV"), qEnvironmentVariable("GRASSFIELD_SESSION"));
}

inline bool session()
{
    return session(qEnvironmentVariable("GRASSFIELD_SESSION"));
}

// The value of GRASSFIELD_<name> in dev, "" otherwise (name without the prefix, as in Mode.devValue).
inline QString devValue(const char *name)
{
    return devPlumbing(qEnvironmentVariable("GRASSFIELD_DEV"), qEnvironmentVariable("GRASSFIELD_SESSION"),
                       qEnvironmentVariable((QByteArrayLiteral("GRASSFIELD_") + name).constData()));
}

inline QString configDir()
{
    return configDir(qEnvironmentVariable("GRASSFIELD_CONFIG_HOME"), qEnvironmentVariable("XDG_CONFIG_HOME"), QDir::homePath());
}

inline QString stateDir()
{
    return stateDir(qEnvironmentVariable("GRASSFIELD_STATE_HOME"), qEnvironmentVariable("XDG_STATE_HOME"), QDir::homePath());
}

// The arguments after `qs` of a call into the running shell: ipc -p <shell dir> call (then target, function, arguments).
// Empty when there is no shell to call: a dev session without GRASSFIELD_SHELL_DIR. The caller must refuse then (an error
// the user can read), never fall back to another shell.
inline QStringList shellIpcArgs()
{
    const QString dir = shellDir(qEnvironmentVariable("GRASSFIELD_DEV"), qEnvironmentVariable("GRASSFIELD_SESSION"), qEnvironmentVariable("GRASSFIELD_SHELL_DIR"));
    if (dir.isEmpty())
        return {};
    return {QStringLiteral("ipc"), QStringLiteral("-p"), dir, QStringLiteral("call")};
}

// GRASSFIELD_STATE_HOME as set ("" when unset): the dev sessions' own state directory, honoured in every session like
// stateDir() (ADR-0019: always honoured). The one reader of the variable besides stateDir().
inline QString stateHomeOverride()
{
    return qEnvironmentVariable("GRASSFIELD_STATE_HOME");
}

} // namespace grassfield::apps::runmode
