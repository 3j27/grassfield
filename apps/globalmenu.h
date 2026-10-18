// Shared by the three Grassfield apps (R5: one copy). Global menus, master-prompt 5.7 T1 and ADR-0008.
#pragma once

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QString>

namespace grassfield::apps {

// True when com.canonical.AppMenu.Registrar is on the session bus. Qt's platform theme then exports a window's
// platform menu bar through DBusMenu (QGenericUnixTheme checks the same name, once, at the first menu bar) and Qt's
// Wayland client announces it with org_kde_kwin_appmenu; grassfield-menu-bridge owns the name only while the shell
// can show those menus. The apps create their Qt.labs.platform MenuBar only then: without a platform menu bar the
// labs menus fall back to widget menus, which a QGuiApplication does not have (an error at every start). Either way
// the in-window controls stay; without the registrar the menu bar shows the T0 menus.
inline bool globalMenuAvailable()
{
    const QDBusConnection bus = QDBusConnection::sessionBus();
    const QDBusConnectionInterface *iface = bus.isConnected() ? bus.interface() : nullptr;
    return iface && iface->isServiceRegistered(QStringLiteral("com.canonical.AppMenu.Registrar")).value();
}

} // namespace grassfield::apps
