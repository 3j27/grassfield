// One Grassfield Memos per user (ADR-0051 D-2): two processes never write the one store. The pattern of Grassfield Store's
// (apps/store/src/storeinstance.h, itself Settings' and Activity Monitor's): the running app owns a name on the session bus,
// object /org/grassfield/Memos, interface org.grassfield.Memos; a second launch hands it its xdg-activation token, and
// leaves. Activate(s token) brings the memos forward, or opens a new memo when none is open.
//
// The name: org.grassfield.Memos in the session; a run with its own state directory (a dev session, an isolated test run:
// GRASSFIELD_STATE_HOME) adds ".Dev" in a dev session and a digest of that directory, as Store's does.
#pragma once

#include "runmode.h"

#include <QCryptographicHash>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDir>
#include <QObject>
#include <QString>

namespace memos {

class MemosInstance : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.grassfield.Memos") // i18n-ignore: a class info key

public:
    using QObject::QObject;

    static QString serviceName()
    {
        namespace runmode = grassfield::apps::runmode;
        QString name = runmode::dev() ? QStringLiteral("org.grassfield.Memos.Dev") : QStringLiteral("org.grassfield.Memos");
        const QString stateHome = runmode::stateHomeOverride();
        if (!stateHome.isEmpty()) {
            const QByteArray digest = QCryptographicHash::hash(QDir(stateHome).absolutePath().toUtf8(), QCryptographicHash::Sha256);
            name += QStringLiteral(".s") + QString::fromLatin1(digest.toHex().left(16));
        }
        return name;
    }
    static QString objectPath() { return QStringLiteral("/org/grassfield/Memos"); }
    static QString interfaceName() { return QStringLiteral("org.grassfield.Memos"); }

    // An xdg-activation token is a short printable string; anything else is dropped (the memos still come forward).
    static QString cleanToken(const QString &token)
    {
        bool printable = token.size() <= 256;
        for (const QChar ch : token)
            printable = printable && ch.unicode() > 0x20 && ch.unicode() < 0x7f;
        return printable ? token : QString();
    }

public slots:
    Q_SCRIPTABLE void Activate(const QString &token) { emit activateRequested(cleanToken(token)); }

signals:
    void activateRequested(const QString &token);
};

enum class Launch { Run, Leave };

// A launch takes the bus name (Run), or hands its token over to the Memos that holds it and leaves (Leave), whatever the
// answer; it runs only when the name has no owner left, after taking it (Store's rule). `answerMs` bounds the wait.
inline Launch claimOrHandOver(QDBusConnection &bus, MemosInstance *instance, const QString &token, int answerMs = 25000)
{
    bus.registerObject(MemosInstance::objectPath(), instance, QDBusConnection::ExportScriptableSlots);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (bus.registerService(MemosInstance::serviceName()))
            return Launch::Run;
        QDBusMessage call = QDBusMessage::createMethodCall(MemosInstance::serviceName(), MemosInstance::objectPath(),
                                                           MemosInstance::interfaceName(), QStringLiteral("Activate"));
        call << token;
        const QDBusMessage reply = bus.call(call, QDBus::Block, answerMs);
        if (reply.type() == QDBusMessage::ReplyMessage)
            return Launch::Leave;
        const QString error = reply.errorName();
        const bool noOwner = error == QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            || error == QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner")
            || (bus.interface() && !bus.interface()->isServiceRegistered(MemosInstance::serviceName()).value());
        if (!noOwner)
            return Launch::Leave;
    }
    return Launch::Leave;
}

} // namespace memos
