#pragma once

// D-Bus objects exported by grassfield-menu-bridge.
//
// Registrar (com.canonical.AppMenu.Registrar at /com/canonical/AppMenu/Registrar): its only job is to EXIST while
// the whole global-menu chain works, because Qt and Chromium export their menus (and announce them through
// org_kde_kwin_appmenu) only when this name is owned. Wayland clients never call it (spike S5). Every method
// answers an error, so nothing pretends to keep a registration:
//   RegisterWindow(u, o), UnregisterWindow(u) -> com.canonical.AppMenu.Registrar.Error.NotSupported
//   GetMenuForWindow(u)                      -> com.canonical.AppMenu.Registrar.Error.NotFound
//   GetMenus()                               -> org.freedesktop.DBus.Error.NotSupported
// (X11/XWayland windows, which do call RegisterWindow, are not supported; see docs/specs/menu-bridge.md.)
//
// Diagnostics (org.grassfield.MenuBridge1 at /org/grassfield/MenuBridge1, XML in bridges/menu-bridge/dbus/):
//   Version() -> s      "<bridge version> menu/1"
//   Status()  -> a{sv}  {"state": s, "registrar": b, "shell": b, "menus": u}

#include <QDBusVirtualObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <functional>

namespace gf::menubridge {

    inline constexpr char kRegistrarService[]   = "com.canonical.AppMenu.Registrar";
    inline constexpr char kRegistrarPath[]      = "/com/canonical/AppMenu/Registrar";
    inline constexpr char kDiagnosticsService[] = "org.grassfield.MenuBridge1";
    inline constexpr char kDiagnosticsPath[]    = "/org/grassfield/MenuBridge1";

    // The <interface> element of org.grassfield.MenuBridge1, identical to the one in
    // bridges/menu-bridge/dbus/org.grassfield.MenuBridge1.xml (checked by a unit test).
    QString diagnosticsInterfaceXml();

    class RegistrarObject : public QDBusVirtualObject {
      public:
        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

      private:
        QSet<QString> m_logged; // "<sender> <member>": one log line each
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
