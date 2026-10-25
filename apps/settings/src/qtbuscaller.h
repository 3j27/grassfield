#pragma once

#include "systembus.h"

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>

namespace grassfield::settings {

// The real caller: one blocking call at a time on a D-Bus connection of its own (the worker threads of Backend each make
// one; the bus is the system bus, which Qt takes from DBUS_SYSTEM_BUS_ADDRESS when it is set: the integration tests point it at
// a private bus).
class QtBusCaller : public BusCaller
{
public:
    explicit QtBusCaller(const QDBusConnection &connection)
        : m_connection(connection)
    {
    }

    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override
    {
        BusReply out;
        if (!m_connection.isConnected()) {
            out.error = QStringLiteral("org.freedesktop.DBus.Error.NoServer: no connection to the system bus"); // i18n-ignore: an error name, mapped to text by reasonOf
            return out;
        }
        QDBusMessage message = QDBusMessage::createMethodCall(service, path, iface, member);
        message.setArguments(args);
        const QDBusMessage reply = m_connection.call(message, QDBus::Block, timeoutMs);
        if (reply.type() == QDBusMessage::ErrorMessage) {
            out.error = reply.errorName() + QStringLiteral(": ") + reply.errorMessage();
            return out;
        }
        out.ok = true;
        out.args = reply.arguments();
        return out;
    }

private:
    QDBusConnection m_connection;
};

} // namespace grassfield::settings
