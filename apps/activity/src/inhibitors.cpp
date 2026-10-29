#include "inhibitors.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

QDBusArgument &operator<<(QDBusArgument &arg, const activity::Inhibitor &i)
{
    arg.beginStructure();
    arg << i.what << i.who << i.why << i.mode << i.uid << i.pid;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, activity::Inhibitor &i)
{
    arg.beginStructure();
    arg >> i.what >> i.who >> i.why >> i.mode >> i.uid >> i.pid;
    arg.endStructure();
    return arg;
}

namespace activity {

QSet<int> sleepPreventers(const QList<Inhibitor> &inhibitors)
{
    QSet<int> pids;
    for (const Inhibitor &i : inhibitors) {
        if (i.mode != QLatin1String("block") || i.pid == 0)
            continue;
        const QStringList what = i.what.split(QLatin1Char(':'), Qt::SkipEmptyParts);
        if (what.contains(QLatin1String("sleep")) || what.contains(QLatin1String("idle")))
            pids.insert(static_cast<int>(i.pid));
    }
    return pids;
}

InhibitorWatch::InhibitorWatch(QObject *parent)
    : QObject(parent)
{
    qDBusRegisterMetaType<Inhibitor>();
    qDBusRegisterMetaType<QList<Inhibitor>>();
}

void InhibitorWatch::refresh()
{
    if (m_pending)
        return;
    QDBusConnection bus = QDBusConnection::systemBus();
    if (!bus.isConnected())
        return; // no system bus (a container): nobody prevents sleep
    const QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.login1"), QStringLiteral("/org/freedesktop/login1"),
                                                             QStringLiteral("org.freedesktop.login1.Manager"),
                                                             QStringLiteral("ListInhibitors"));
    m_pending = true;
    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, 2000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        m_pending = false;
        const QDBusPendingReply<QList<Inhibitor>> reply = *w;
        w->deleteLater();
        const QSet<int> pids = reply.isValid() ? sleepPreventers(reply.value()) : QSet<int>();
        if (pids != m_pids) {
            m_pids = pids;
            emit changed();
        }
    });
}

} // namespace activity
