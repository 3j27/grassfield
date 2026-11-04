// One Settings per user (macOS: one Settings window and one About This Computer window; review of ce69dc6, ADR-0040 step
// 1b). The pattern of Activity Monitor's AM1 (ADR-0038 AD34): the running Settings owns a name on the session bus, object
// /org/grassfield/Settings, interface org.grassfield.Settings; a second launch hands it what it was asked for, with its
// xdg-activation token, and leaves. Open(s section, s token) shows the Settings window (on `section` when one is given),
// About(s token) the About This Computer window. More Info… asks the same object in the process (openSettings).
//
// The name: org.grassfield.Settings in the session; a run with its own state directory (a dev session, an isolated test run:
// GRASSFIELD_STATE_HOME, scripts/dev/isolated.sh) shares the owner's session bus, so its name adds ".Dev" in a dev session
// and a digest of that directory, and never reaches the owner's Settings, nor another run's.
//
// claimOrHandOver, activateWindow and askShellToReopen repeat Activity Monitor's (apps/activity/src/activityapp.cpp,
// shownwatch.h) until the two apps share one header.
#pragma once

#include "runmode.h"

#include <QCryptographicHash>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDir>
#include <QObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QWindow>

namespace grassfield::settings {

class SettingsInstance : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.grassfield.Settings") // i18n-ignore: a class info key

public:
    using QObject::QObject;

    static QString serviceName()
    {
        namespace runmode = grassfield::apps::runmode;
        QString name = runmode::dev() ? QStringLiteral("org.grassfield.Settings.Dev") : QStringLiteral("org.grassfield.Settings");
        const QString stateHome = runmode::stateHomeOverride();
        if (!stateHome.isEmpty()) {
            const QByteArray digest = QCryptographicHash::hash(QDir(stateHome).absolutePath().toUtf8(), QCryptographicHash::Sha256);
            name += QStringLiteral(".s") + QString::fromLatin1(digest.toHex().left(16));
        }
        return name;
    }
    static QString objectPath() { return QStringLiteral("/org/grassfield/Settings"); }
    static QString interfaceName() { return QStringLiteral("org.grassfield.Settings"); }

    // A section id as the sidebar names them ("wifi", "software-update"); anything else is "" (the window as it is). It may end
    // in "@<output name>" ("wallpaper@DP-2": Wallpaper preselected on that display; `--section=wallpaper --display=DP-2`).
    static QString cleanSection(const QString &section)
    {
        static const QRegularExpression id(QRegularExpression::anchoredPattern(QStringLiteral("[a-z][a-z0-9-]{0,39}(@[A-Za-z0-9._:-]{1,64})?")));
        return id.match(section).hasMatch() ? section : QString();
    }

    // An xdg-activation token is a short printable string; anything else is dropped (the window still comes forward).
    static QString cleanToken(const QString &token)
    {
        bool printable = token.size() <= 256;
        for (const QChar ch : token)
            printable = printable && ch.unicode() > 0x20 && ch.unicode() < 0x7f;
        return printable ? token : QString();
    }

    // More Info… (AboutWindow.qml): the Settings window at `section`, in this process (the click's own activation).
    Q_INVOKABLE void openSettings(const QString &section) { emit settingsRequested(cleanSection(section), QString()); }

public slots:
    Q_SCRIPTABLE void Open(const QString &section, const QString &token) { emit settingsRequested(cleanSection(section), cleanToken(token)); }
    Q_SCRIPTABLE void About(const QString &token) { emit aboutRequested(cleanToken(token)); }

signals:
    void settingsRequested(const QString &section, const QString &token);
    void aboutRequested(const QString &token);
};

enum class Launch { Run, Leave };

// A launch takes the bus name (Run), or hands its request over to the Settings that holds it and leaves (Leave): `method` is
// "Open" or "About", `arguments` its arguments. The running Settings answers from its event loop, once its windows exist,
// which a slow start delays (the re-review of c6cf328: a launch that gave up after 2 s opened a second Settings while the
// first was still starting; Activity Monitor's claimOrHandOver, ADR-0038, for the same race): a launch leaves whatever the
// answer, and runs only when the name has no owner left, after taking it. `answerMs` bounds the wait for the delivery; a
// request that waited past it is still queued for the running Settings, which acts on it once it runs its loop.
inline Launch claimOrHandOver(QDBusConnection &bus, SettingsInstance *instance, const QString &method, const QVariantList &arguments,
                              int answerMs = 25000)
{
    bus.registerObject(SettingsInstance::objectPath(), instance, QDBusConnection::ExportScriptableSlots);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (bus.registerService(SettingsInstance::serviceName()))
            return Launch::Run;
        QDBusMessage call = QDBusMessage::createMethodCall(SettingsInstance::serviceName(), SettingsInstance::objectPath(),
                                                           SettingsInstance::interfaceName(), method);
        call.setArguments(arguments);
        const QDBusMessage reply = bus.call(call, QDBus::Block, answerMs);
        if (reply.type() == QDBusMessage::ReplyMessage)
            return Launch::Leave;
        // Only a name left meanwhile is taken: the bus said it has no owner, or, whatever the error, it has none now (the
        // running Settings died while it was asked: the bus answers NoReply; the re-review of 85c2c10, whose click was lost).
        // A running Settings that answers late (still starting) or not at all keeps its one window, as a busy app on macOS
        // opens nothing more.
        const QString error = reply.errorName();
        const bool noOwner = error == QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            || error == QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner")
            || (bus.interface() && !bus.interface()->isServiceRegistered(SettingsInstance::serviceName()).value());
        if (!noOwner)
            return Launch::Leave;
    }
    return Launch::Leave;
}

// The shell's Dock brings Settings' windows back (`qs ipc -p <shell> call dock reopen org.grassfield.Settings`, what a click
// on its tile does): xdg-activation switches to another Desktop but leaves a window on special:minimized (AD34). Nothing
// when there is no shell to call (a dev session that names none: the installed shell is never driven from it, runmode.h).
// Run detached, without the QS_* variables (the shell is named by its directory) or a spent token.
inline void askShellToReopen()
{
    const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
    if (ipc.isEmpty())
        return;
    const QStringList command = QStringList{QStringLiteral("qs")} + ipc
        + QStringList{QStringLiteral("dock"), QStringLiteral("reopen"), QStringLiteral("org.grassfield.Settings")};
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const QString &key : env.keys()) {
        if (key.startsWith(QLatin1String("QS_")))
            env.remove(key);
    }
    env.remove(QStringLiteral("XDG_ACTIVATION_TOKEN"));
    QProcess process;
    process.setProcessEnvironment(env);
    process.setProgram(command.first());
    process.setArguments(command.mid(1));
    process.setStandardOutputFile(QProcess::nullDevice());
    process.setStandardErrorFile(QProcess::nullDevice());
    process.startDetached();
}

// A window asked for again comes forward: a closed one is shown again (it maps, and Hyprland focuses a new mapping), Qt's
// next activation request takes the token (xdg-activation-v1) and the window is raised; a shown one off screen (minimized, or
// on another Desktop) is brought back by the Dock. The window's states are left alone (on Wayland Qt asks the compositor for
// whatever setWindowStates gives; AD34), only a Minimized state Qt still holds is cleared.
inline void activateWindow(QWindow *window, const QString &token)
{
    if (!window)
        return;
    const bool offScreen = window->isVisible() && (!window->isExposed() || window->visibility() == QWindow::Minimized);
    if (!token.isEmpty())
        qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
    if (window->windowStates() & Qt::WindowMinimized)
        window->setWindowStates(window->windowStates() & ~Qt::WindowMinimized);
    if (!window->isVisible())
        window->show();
    window->raise();
    window->requestActivate();
    if (offScreen)
        askShellToReopen();
}

} // namespace grassfield::settings
