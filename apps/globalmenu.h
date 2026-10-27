// Shared by the three Grassfield apps (R5: one copy). Global menus, master-prompt 5.7 T1 and ADR-0008.
#pragma once

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusServiceWatcher>
#include <QGuiApplication>
#include <QKeySequence>
#include <QObject>
#include <QPointer>
#include <QShortcut>
#include <QString>
#include <QTimer>

namespace grassfield::apps {

// Qt.labs.platform's MenuItem (Qt 6.11) keeps -1 for "no key registered", and -1 is also the id Qt's shortcut map gives
// the first key registered in a process (the map counts down from -1). The menu item that gets it never takes its key
// back: not when it is disabled (the key still triggers it), not when its key changes, not when it is destroyed. Once
// that item is gone (its window closed, or the registrar went away), the next press of its key in the app reads the
// deleted item: SIGSEGV in QQuickShortcutContext::matcher, called from QShortcutMap::find. Each app calls this right
// after creating its application object, before any QML exists: a disabled key that never matches takes id -1, so no
// menu item can get it, whatever order the QML registers its keys in (tests/unit/files/tst_menushortcuts.cpp).
inline void reserveFirstShortcutId(QGuiApplication &app)
{
    // Never acts: a window shortcut owned by no window does not match, and it is disabled.
    auto *placeholder = new QShortcut(QKeySequence(Qt::Key_F35), &app);
    placeholder->setEnabled(false);
}

inline QString globalMenuRegistrar()
{
    return QStringLiteral("com.canonical.AppMenu.Registrar");
}

// True when com.canonical.AppMenu.Registrar is on the session bus. Qt's platform theme then exports a window's
// platform menu bar through DBusMenu and Qt's Wayland client announces it with org_kde_kwin_appmenu;
// grassfield-menu-bridge owns the name only while the shell can show those menus. The apps create their
// Qt.labs.platform MenuBar only then: without a platform menu bar the labs menus fall back to widget menus, which a
// QGuiApplication does not have (an error at every start). Either way the in-window controls stay; without the
// registrar the menu bar shows the T0 menus. Qt's theme checks the name once, at the first menu bar it creates
// (QGenericUnixTheme caches it), which is why no MenuBar may exist before the registrar does.
inline bool globalMenuAvailable()
{
    const QDBusConnection bus = QDBusConnection::sessionBus();
    const QDBusConnectionInterface *iface = bus.isConnected() ? bus.interface() : nullptr;
    return iface && iface->isServiceRegistered(globalMenuRegistrar()).value();
}

// Keeps the bool property `property` of `target` (the QML root object) equal to "the registrar is on the session bus"
// for the life of `target`, so an app started before the registrar gets its global menu once the registrar appears,
// and drops it when the registrar goes away. A new owner (the bridge restarted, or replaced) reads as a disappearance
// followed by an appearance: the QML side destroys its MenuBar and creates a fresh one, whose DBusMenu export reaches
// the new registrar. The appearance is applied on the next event loop turn, after the old MenuBar is gone.
inline void followGlobalMenu(QObject *target, const char *property)
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!target || !bus.isConnected())
        return;
    auto *watcher = new QDBusServiceWatcher(globalMenuRegistrar(), bus, QDBusServiceWatcher::WatchForOwnerChange, target);
    const QPointer<QObject> guard(target);
    QObject::connect(watcher, &QDBusServiceWatcher::serviceOwnerChanged, target,
                     [guard, property](const QString &, const QString &oldOwner, const QString &newOwner) {
                         if (!guard)
                             return;
                         if (!oldOwner.isEmpty()) {
                             qInfo("grassfield: global menu registrar gone (%s)", qUtf8Printable(oldOwner));
                             guard->setProperty(property, false);
                         }
                         if (newOwner.isEmpty())
                             return;
                         QTimer::singleShot(0, guard.data(), [guard, property] {
                             if (!guard)
                                 return;
                             const bool available = globalMenuAvailable();
                             qInfo("grassfield: global menu registrar %s", available ? "available" : "gone again");
                             guard->setProperty(property, available);
                         });
                     });
    // A registrar that appeared or went away between the initial check and the watch.
    target->setProperty(property, globalMenuAvailable());
}

} // namespace grassfield::apps
