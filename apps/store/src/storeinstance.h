// One Grassfield Store per user (macOS: one App Store window; step 4, for Files' "Search the Store", ADR-0035 5c-3). The
// pattern of Settings' (apps/settings/src/settingsinstance.h) and Activity Monitor's (ADR-0038 AD34): the running Store
// owns a name on the session bus, object /org/grassfield/Store, interface org.grassfield.Store; a second launch hands it its
// --page and its xdg-activation token, and leaves. Open(s page, s token) brings the window forward on that page (the page
// is checked again by the window, Main.qml's openPage; an unknown one keeps the page shown).
//
// The name: org.grassfield.Store in the session; a run with its own state directory (a dev session, an isolated test run:
// GRASSFIELD_STATE_HOME) adds ".Dev" in a dev session and a digest of that directory, as Settings' does.
//
// claimOrHandOver and activateWindow repeat Settings' until the apps share one header.
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
#include <QString>
#include <QStringList>
#include <QWindow>

namespace grassfield::store {

class StoreInstance : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.grassfield.Store") // i18n-ignore: a class info key

public:
    using QObject::QObject;

    static QString serviceName()
    {
        namespace runmode = grassfield::apps::runmode;
        QString name = runmode::dev() ? QStringLiteral("org.grassfield.Store.Dev") : QStringLiteral("org.grassfield.Store");
        const QString stateHome = runmode::stateHomeOverride();
        if (!stateHome.isEmpty()) {
            const QByteArray digest = QCryptographicHash::hash(QDir(stateHome).absolutePath().toUtf8(), QCryptographicHash::Sha256);
            name += QStringLiteral(".s") + QString::fromLatin1(digest.toHex().left(16));
        }
        return name;
    }
    static QString objectPath() { return QStringLiteral("/org/grassfield/Store"); }
    static QString interfaceName() { return QStringLiteral("org.grassfield.Store"); }

    // A page as --page takes it: printable, at most 512 characters, else "" (the window as it is). Its form is the window's
    // to check (Main.qml's openPage).
    static QString cleanPage(const QString &page)
    {
        bool printable = page.size() <= 512;
        for (const QChar ch : page)
            printable = printable && ch.unicode() >= 0x20 && ch.unicode() != 0x7f;
        return printable ? page : QString();
    }

    // An xdg-activation token is a short printable string; anything else is dropped (the window still comes forward).
    static QString cleanToken(const QString &token)
    {
        bool printable = token.size() <= 256;
        for (const QChar ch : token)
            printable = printable && ch.unicode() > 0x20 && ch.unicode() < 0x7f;
        return printable ? token : QString();
    }

public slots:
    Q_SCRIPTABLE void Open(const QString &page, const QString &token) { emit openRequested(cleanPage(page), cleanToken(token)); }

signals:
    void openRequested(const QString &page, const QString &token);
};

enum class Launch { Run, Leave };

// A launch takes the bus name (Run), or hands its page over to the Store that holds it and leaves (Leave), whatever the
// answer; it runs only when the name has no owner left, after taking it (Settings' rule, the re-reviews of c6cf328 and
// 85c2c10). `answerMs` bounds the wait for the delivery.
inline Launch claimOrHandOver(QDBusConnection &bus, StoreInstance *instance, const QString &page, const QString &token, int answerMs = 25000)
{
    bus.registerObject(StoreInstance::objectPath(), instance, QDBusConnection::ExportScriptableSlots);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (bus.registerService(StoreInstance::serviceName()))
            return Launch::Run;
        QDBusMessage call = QDBusMessage::createMethodCall(StoreInstance::serviceName(), StoreInstance::objectPath(),
                                                           StoreInstance::interfaceName(), QStringLiteral("Open"));
        call << page << token;
        const QDBusMessage reply = bus.call(call, QDBus::Block, answerMs);
        if (reply.type() == QDBusMessage::ReplyMessage)
            return Launch::Leave;
        const QString error = reply.errorName();
        const bool noOwner = error == QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            || error == QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner")
            || (bus.interface() && !bus.interface()->isServiceRegistered(StoreInstance::serviceName()).value());
        if (!noOwner)
            return Launch::Leave;
    }
    return Launch::Leave;
}

// The shell's Dock brings the Store's window back (`qs ipc -p <shell> call dock reopen org.grassfield.Store`, what a click on
// its tile does) when xdg-activation cannot: a minimized window, or one on another Desktop (AD34).
inline void askShellToReopen()
{
    const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
    if (ipc.isEmpty())
        return;
    const QStringList command = QStringList{QStringLiteral("qs")} + ipc
        + QStringList{QStringLiteral("dock"), QStringLiteral("reopen"), QStringLiteral("org.grassfield.Store")};
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

// The window asked for again comes forward (Settings' activateWindow): shown again if closed, the token for Qt's next
// activation request, raised; one off screen is brought back by the Dock.
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

} // namespace grassfield::store
