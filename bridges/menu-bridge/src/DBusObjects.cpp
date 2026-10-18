#include "DBusObjects.h"

#include "Log.h"
#include "Protocol.h"

#include <QDBusConnection>
#include <QDBusMessage>

namespace gf::menubridge {

    QString diagnosticsInterfaceXml() {
        return QStringLiteral(R"XML(  <interface name="org.grassfield.MenuBridge1">
    <method name="Version">
      <arg name="version" type="s" direction="out"/>
    </method>
    <method name="Status">
      <arg name="status" type="a{sv}" direction="out"/>
    </method>
  </interface>
)XML");
    }

    QString RegistrarObject::introspect(const QString& /*path*/) const {
        return QStringLiteral(R"XML(  <interface name="com.canonical.AppMenu.Registrar">
    <method name="RegisterWindow"><arg name="windowId" type="u" direction="in"/><arg name="menuObjectPath" type="o" direction="in"/></method>
    <method name="UnregisterWindow"><arg name="windowId" type="u" direction="in"/></method>
    <method name="GetMenuForWindow"><arg name="windowId" type="u" direction="in"/><arg name="service" type="s" direction="out"/><arg name="menuObjectPath" type="o" direction="out"/></method>
    <method name="GetMenus"><arg name="menus" type="a(uso)" direction="out"/></method>
  </interface>
)XML");
    }

    bool answersByDefault(const QString& interface) {
        // Left to QtDBus (cheap, answers without any state): introspection and pings.
        return interface == QLatin1String("org.freedesktop.DBus.Introspectable") || interface == QLatin1String("org.freedesktop.DBus.Peer");
    }

    bool RegistrarObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true; // signals and replies are never for this object
        if (answersByDefault(message.interface()))
            return false;
        // Only the registrar methods get an answer; any other call on this path is dropped without a reply (the
        // message is already buffered by libdbus, but nothing is built for it).
        if (message.interface() != QLatin1String(kRegistrarService))
            return true;
        const QString member = message.member();
        QString       error;
        QString       text;
        if (member == QLatin1String("RegisterWindow") || member == QLatin1String("UnregisterWindow")) {
            error = QStringLiteral("com.canonical.AppMenu.Registrar.Error.NotSupported");
            text  = QStringLiteral("Grassfield links menus to windows through org_kde_kwin_appmenu; X11 window ids are not supported");
        } else if (member == QLatin1String("GetMenuForWindow")) {
            error = QStringLiteral("com.canonical.AppMenu.Registrar.Error.NotFound");
            text  = QStringLiteral("no registration is kept by this registrar");
        } else if (member == QLatin1String("GetMenus")) {
            error = QStringLiteral("org.freedesktop.DBus.Error.NotSupported");
            text  = QStringLiteral("GetMenus is not implemented");
        } else
            return true; // not a registrar method: dropped
        const QString key = message.service() + u' ' + member;
        if (!m_logged.contains(key) && m_logged.size() < 256) {
            m_logged.insert(key);
            log(QStringLiteral("registrar: %1 from %2 answered %3").arg(member, message.service(), error));
        }
        connection.send(message.createErrorReply(error, text));
        return true;
    }

    QString DiagnosticsObject::introspect(const QString& /*path*/) const {
        return diagnosticsInterfaceXml();
    }

    bool DiagnosticsObject::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
        if (message.type() != QDBusMessage::MethodCallMessage)
            return true;
        if (answersByDefault(message.interface()))
            return false;
        if (message.interface() != QLatin1String(kDiagnosticsService) || !message.arguments().isEmpty())
            return true; // dropped

        if (message.member() == QLatin1String("Version")) {
            connection.send(message.createReply(QStringLiteral("%1 %2").arg(QLatin1String(kBridgeVersion), QLatin1String(kProtocol))));
            return true;
        }
        if (message.member() == QLatin1String("Status")) {
            connection.send(message.createReply(QVariant(m_status())));
            return true;
        }
        return true; // unknown member: dropped
    }

} // namespace gf::menubridge
