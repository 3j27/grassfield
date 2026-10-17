// SPDX-License-Identifier: MIT
// fake-registrar: a minimal com.canonical.AppMenu.Registrar for spike S5 and appmenu tests. TEST FIXTURE ONLY.
//
// Qt creates its DBusMenu menu bar (QDBusMenuBar) only when this service is present on the session bus. Owning
// this name on the OWNER'S session bus would make the Qt/KDE apps of the owner's real session hide their menu
// bars, so the fixture refuses to start unless:
//   - GRASSFIELD_PRIVATE_BUS=1 is set (explicit intent), and
//   - no well-known name other than org.freedesktop.DBus is owned on the bus (a fresh dbus-run-session bus;
//     a real session bus has systemd, portals, notifications, ...).
// Run it as: dbus-run-session -- env GRASSFIELD_PRIVATE_BUS=1 fake-registrar   (see tests/compositor/appmenu.sh)
//
// It logs every call on stdout ("fake-registrar: ..."), stores registrations in memory, and implements
// RegisterWindow(u windowId, o menuObjectPath), UnregisterWindow(u), GetMenuForWindow(u) -> (s, o), with the
// WindowRegistered / WindowUnregistered signals (GetMenus answers NotSupported).
//
// Build: tests/fixtures/fake-registrar/build.sh (g++ + pkg-config Qt6DBus; no moc needed).

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusVirtualObject>
#include <QMap>
#include <QStringList>

#include <cstdio>
#include <utility>

namespace {
    const QString kService   = QStringLiteral("com.canonical.AppMenu.Registrar");
    const QString kPath      = QStringLiteral("/com/canonical/AppMenu/Registrar");
    const QString kInterface = QStringLiteral("com.canonical.AppMenu.Registrar");

    void say(const QString& line) {
        std::fprintf(stdout, "fake-registrar: %s\n", qPrintable(line));
        std::fflush(stdout);
    }

    class CRegistrar : public QDBusVirtualObject {
      public:
        QString introspect(const QString& /*path*/) const override {
            return QString::fromUtf8(R"XML(<interface name="com.canonical.AppMenu.Registrar">
  <method name="RegisterWindow"><arg name="windowId" type="u" direction="in"/><arg name="menuObjectPath" type="o" direction="in"/></method>
  <method name="UnregisterWindow"><arg name="windowId" type="u" direction="in"/></method>
  <method name="GetMenuForWindow"><arg name="windowId" type="u" direction="in"/><arg name="service" type="s" direction="out"/><arg name="menuObjectPath" type="o" direction="out"/></method>
  <method name="GetMenus"><arg name="menus" type="a(uso)" direction="out"/></method>
  <signal name="WindowRegistered"><arg name="windowId" type="u"/><arg name="service" type="s"/><arg name="menuObjectPath" type="o"/></signal>
  <signal name="WindowUnregistered"><arg name="windowId" type="u"/></signal>
</interface>
)XML");
        }

        bool handleMessage(const QDBusMessage& msg, const QDBusConnection& conn) override {
            if (msg.interface() != kInterface)
                return false;
            const QString     member = msg.member();
            const QVariantList args  = msg.arguments();
            if (member == QLatin1String("RegisterWindow") && args.size() == 2) {
                const uint    id   = args.at(0).toUInt();
                const QString path = qvariant_cast<QDBusObjectPath>(args.at(1)).path();
                m_windows.insert(id, {msg.service(), path});
                say(QStringLiteral("RegisterWindow id=%1 service=%2 path=%3").arg(id).arg(msg.service(), path));
                conn.send(msg.createReply());
                auto sig = QDBusMessage::createSignal(kPath, kInterface, QStringLiteral("WindowRegistered"));
                sig << id << msg.service() << QVariant::fromValue(QDBusObjectPath(path));
                conn.send(sig);
                return true;
            }
            if (member == QLatin1String("UnregisterWindow") && args.size() == 1) {
                const uint id = args.at(0).toUInt();
                m_windows.remove(id);
                say(QStringLiteral("UnregisterWindow id=%1 from %2").arg(id).arg(msg.service()));
                conn.send(msg.createReply());
                auto sig = QDBusMessage::createSignal(kPath, kInterface, QStringLiteral("WindowUnregistered"));
                sig << id;
                conn.send(sig);
                return true;
            }
            if (member == QLatin1String("GetMenuForWindow") && args.size() == 1) {
                const uint id = args.at(0).toUInt();
                say(QStringLiteral("GetMenuForWindow id=%1").arg(id));
                const auto it = m_windows.constFind(id);
                if (it == m_windows.constEnd()) {
                    conn.send(msg.createErrorReply(QStringLiteral("com.canonical.AppMenu.Registrar.Error.NotFound"), QStringLiteral("no menu for this window")));
                    return true;
                }
                conn.send(msg.createReply(QVariantList{it->first, QVariant::fromValue(QDBusObjectPath(it->second))}));
                return true;
            }
            if (member == QLatin1String("GetMenus") && args.isEmpty()) {
                // Not needed by Qt or the tests (a(uso) needs a registered D-Bus struct type).
                say(QStringLiteral("GetMenus (%1 registered): not supported").arg(m_windows.size()));
                conn.send(msg.createErrorReply(QStringLiteral("org.freedesktop.DBus.Error.NotSupported"), QStringLiteral("GetMenus is not implemented by this fixture")));
                return true;
            }
            return false;
        }

      private:
        QMap<uint, std::pair<QString, QString>> m_windows;
    };
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);

    if (qgetenv("GRASSFIELD_PRIVATE_BUS") != "1") {
        say(QStringLiteral("refusing to start: GRASSFIELD_PRIVATE_BUS=1 is not set (run inside dbus-run-session)"));
        return 3;
    }
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected() || !bus.interface()) {
        say(QStringLiteral("no session bus"));
        return 2;
    }
    QStringList others;
    for (const QString& name : bus.interface()->registeredServiceNames().value()) {
        if (!name.startsWith(QLatin1Char(':')) && name != QLatin1String("org.freedesktop.DBus"))
            others << name;
    }
    if (!others.isEmpty()) {
        say(QStringLiteral("refusing to start: this bus already has %1 well-known name(s) (%2...): not a private test bus").arg(others.size()).arg(others.first()));
        return 3;
    }

    CRegistrar registrar;
    if (!bus.registerVirtualObject(kPath, &registrar, QDBusConnection::SingleNode)) {
        say(QStringLiteral("could not register %1").arg(kPath));
        return 2;
    }
    if (!bus.registerService(kService)) {
        say(QStringLiteral("could not own %1").arg(kService));
        return 2;
    }
    say(QStringLiteral("owning %1 on private bus %2 as %3").arg(kService, QString::fromLocal8Bit(qgetenv("DBUS_SESSION_BUS_ADDRESS")), bus.baseService()));
    return QCoreApplication::exec();
}
