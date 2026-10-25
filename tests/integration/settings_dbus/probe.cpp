// The Settings app's Wi-Fi and Bluetooth code (apps/settings/src/systembus.cpp) on a REAL D-Bus connection, for the
// integration test tests/integration/settings_dbus.sh. It talks to the bus named by DBUS_SYSTEM_BUS_ADDRESS, which the test
// sets to a PRIVATE dbus-daemon with fake services, and REFUSES to run on anything else (exit 2), before it connects:
//   probe [--dev] wifi-state | bt-state | act '<json of an action map>'
// Prints the state JSON, or for an action "ok" / "failed: <reason>". Exit 0 ok, 1 failed, 2 refused to run.
#include "qtbuscaller.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QJsonDocument>
#include <QJsonObject>

#include <cstdio>

using namespace grassfield::settings;

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QString address = qEnvironmentVariable("DBUS_SYSTEM_BUS_ADDRESS");
    if (qEnvironmentVariable("GF_TEST_BUS") != QLatin1String("1") || address.isEmpty() || address.contains(QLatin1String("/run/"))
        || address.contains(QLatin1String("/var/run/")) || address.startsWith(QLatin1String("systemd:"))) {
        std::fprintf(stderr, "probe: refusing to run on '%s': only a private test bus (GF_TEST_BUS=1, DBUS_SYSTEM_BUS_ADDRESS)\n", qPrintable(address));
        return 2;
    }
    QStringList args = app.arguments().mid(1);
    bool dev = false;
    if (!args.isEmpty() && args.first() == QLatin1String("--dev")) {
        dev = true;
        args.removeFirst();
    }
    if (args.isEmpty())
        return 2;
    registerBusTypes();
    // QDBusConnection::systemBus() takes DBUS_SYSTEM_BUS_ADDRESS, as the app does.
    const QDBusConnection system = QDBusConnection::systemBus();
    if (!system.isConnected())
        std::fprintf(stderr, "probe: not connected to %s: %s: %s\n", qPrintable(address), qPrintable(system.lastError().name()), qPrintable(system.lastError().message()));
    QtBusCaller real(system);
    GuardedCaller bus(real, dev);
    const QString verb = args.first();
    if (verb == QLatin1String("wifi-state") || verb == QLatin1String("bt-state")) {
        const StateResult r = verb == QLatin1String("wifi-state") ? wifiState(bus) : bluetoothState(bus);
        if (!r.ok) {
            std::printf("failed: %s\n", qPrintable(r.error));
            return 1;
        }
        std::printf("%s\n", QJsonDocument(r.json).toJson(QJsonDocument::Compact).constData());
        return 0;
    }
    if (verb == QLatin1String("act") && args.size() == 2) {
        const QVariantMap op = QJsonDocument::fromJson(args.at(1).toUtf8()).object().toVariantMap();
        const QString reason = runAction(bus, op);
        if (!reason.isEmpty()) {
            std::printf("failed: %s\n", qPrintable(reason));
            return 1;
        }
        std::printf("ok\n");
        return 0;
    }
    return 2;
}
