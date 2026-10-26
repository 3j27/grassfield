#pragma once

// D-Bus objects exported by grassfield-menu-bridge.
//
// Registrar (com.canonical.AppMenu.Registrar at /com/canonical/AppMenu/Registrar): it EXISTS while the whole
// global-menu chain works, because Qt and Chromium export their menus (and announce them through
// org_kde_kwin_appmenu) only when this name is owned; Qt and Chromium never call it on Wayland (spike S5). Electron
// does (ADR-0008 amendment 2026-10-25): its registrations are kept per sender (Registrations.h) and served to the
// windows of the sender's process:
//   RegisterWindow(u, o), UnregisterWindow(u) -> () kept / forgotten (LimitsExceeded past the caps)
//   GetMenuForWindow(u)                      -> com.canonical.AppMenu.Registrar.Error.NotFound
//   GetMenus()                               -> org.freedesktop.DBus.Error.NotSupported
// Only these four methods get an answer; every other call, signal or interface on the registrar and diagnostics paths
// is dropped without a reply, so nothing is built for traffic nobody asked for. (libdbus buffers any incoming message
// before it reaches here: see MB14.) A sender that registers is watched; its pid is asked from the bus daemon once
// (its departure, or no answer, drops its registrations).
//
// Diagnostics (org.grassfield.MenuBridge1 at /org/grassfield/MenuBridge1, XML in bridges/menu-bridge/dbus/):
//   Version() -> s      "<bridge version> menu/1"
//   Status()  -> a{sv}  {"state": s, "registrar": b, "degraded": b, "shell": b, "menus": u}

#include "Registrations.h"

#include <QDBusConnection>
#include <QDBusVirtualObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <functional>

class QDBusServiceWatcher;

namespace gf::menubridge {

    inline constexpr char kRegistrarService[]   = "com.canonical.AppMenu.Registrar";
    inline constexpr char kRegistrarPath[]      = "/com/canonical/AppMenu/Registrar";
    inline constexpr char kDiagnosticsService[] = "org.grassfield.MenuBridge1";
    inline constexpr char kDiagnosticsPath[]    = "/org/grassfield/MenuBridge1";

    // True for the interfaces QtDBus answers on its own (introspection, peer ping).
    bool answersByDefault(const QString& interface);

    // The <interface> element of org.grassfield.MenuBridge1, identical to the one in
    // bridges/menu-bridge/dbus/org.grassfield.MenuBridge1.xml (checked by a unit test).
    QString diagnosticsInterfaceXml();

    class RegistrarObject : public QDBusVirtualObject {
      public:
        // `changed` runs after every change of the book that can matter to a waiting or open window: a registration
        // settled (registrar::kSettleMs after it was kept) or forgotten, a sender's pid learnt, a sender gone.
        explicit RegistrarObject(std::function<void()> changed = {});
        ~RegistrarObject() override;

        RegistrarObject(const RegistrarObject&)            = delete;
        RegistrarObject& operator=(const RegistrarObject&) = delete;

        // Attaches the sender watcher and the pid queries to `connection` (call once, before the object is registered).
        void    setConnection(const QDBusConnection& connection);
        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

        const registrar::Book& book() const {
            return m_book;
        }
        // Forgets every registration (the registrar name was released: applications register again when it returns).
        void clear();

      private:
        static constexpr int kPidTimeoutMs = 2000;
        // Asks the bus daemon for `sender`'s process (after its watch was added: a sender that left before is answered
        // with an error and dropped, a later departure reaches the watch).
        void askPid(const QDBusConnection& connection, const QString& sender);
        void dropSender(const QString& sender);

        registrar::Book       m_book;
        std::function<void()> m_changed;
        QDBusServiceWatcher*  m_watcher = nullptr;
        QSet<QString>         m_logged; // "<sender> <member>": one log line each
    };

    class DiagnosticsObject : public QDBusVirtualObject {
      public:
        explicit DiagnosticsObject(std::function<QVariantMap()> status) : m_status(std::move(status)) {}

        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

      private:
        std::function<QVariantMap()> m_status;
    };

} // namespace gf::menubridge
