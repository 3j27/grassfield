// grassfield-portal-settings (ADR-0035 D-4, D-8; step 2b): the Settings portal backend of the Grassfield session. No window,
// no Qt GUI platform: Qt Core and D-Bus only. Started with the session by grassfield-portal-settings.service (Type=dbus), or by
// D-Bus activation at the frontend's next read after a crash; the frontend lists it before x-d-p-gtk through the session's
// hyprland-portals.conf (/usr/share/grassfield/xdg).
#include "runmode.h"
#include "settingsbackend.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QTime>

#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-portal-settings"));
    namespace runmode = grassfield::apps::runmode;
    if (!runmode::session() && !runmode::dev()) {
        std::fputs("grassfield-portal-settings: refused: not a Grassfield session\n", stderr);
        return 2;
    }

    grassfield::portal::SettingsBackend::Options options;
    options.configFile = runmode::configDir() + QStringLiteral("/grassfield.json");
    options.recheckMs = grassfield::apps::kAutoRecheckMs;
    options.clock = [] { return QTime::currentTime(); };
    // Dev plumbing (ADR-0019), honoured only in a dev session: the tests fix the clock and shorten the recheck.
    if (const QString clock = runmode::devValue("PORTAL_SETTINGS_CLOCK"); !clock.isEmpty()) {
        const QTime fixed = QTime::fromString(clock, QStringLiteral("HH:mm"));
        if (fixed.isValid())
            options.clock = [fixed] { return fixed; };
    }
    if (const int ms = runmode::devValue("PORTAL_SETTINGS_RECHECK_MS").toInt(); ms > 0)
        options.recheckMs = ms;

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        std::fputs("grassfield-portal-settings: no session bus\n", stderr);
        return 1;
    }
    grassfield::portal::SettingsBackend backend(options);
    // The object first, then the name: a caller that sees the name always finds the object.
    if (!bus.registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &backend,
                            QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals | QDBusConnection::ExportAllProperties)) {
        std::fputs("grassfield-portal-settings: cannot export the Settings object\n", stderr);
        return 1;
    }
    if (!bus.registerService(QStringLiteral("org.freedesktop.impl.portal.desktop.grassfield_settings"))) {
        std::fputs("grassfield-portal-settings: the bus name is taken\n", stderr);
        return 1;
    }
    // After a restart (Restart=on-failure), the frontend's proxy follows the name to this process: every value once, so a
    // change made while no backend ran is not lost.
    backend.announceAll();
    return app.exec();
}
