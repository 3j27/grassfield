// The Settings app's Wi-Fi and Bluetooth code (apps/settings/src/systembus.cpp) on a REAL D-Bus connection, for the
// integration test tests/integration/settings_dbus.sh. It talks to the bus named by DBUS_SYSTEM_BUS_ADDRESS, which the test
// sets to a PRIVATE dbus-daemon with fake services, and REFUSES to run on anything else (exit 2), before it connects:
//   probe [--dev] wifi-state | bt-state | net-state | power-state | host-state | time-state | time-zones | locale-state | units-state | act '<json of an action map>'
// Prints the state JSON, or for an action "ok" / "failed: <reason>". Exit 0 ok, 1 failed, 2 refused to run. The user's own
// services (units-state, user.* actions) are on the session bus, as in the app (Backend: a second connection): the test points
// DBUS_SESSION_BUS_ADDRESS at the same private bus, and the probe refuses any other session bus too. Their own folder is
// GF_TEST_BUS_DIR/units.
#include "busjobs.h"
#include "qtbuscaller.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>
#include <QDBusConnection>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>

#include <atomic>
#include <cstdio>
#include <cstdlib>

using namespace grassfield::settings;

// An address is a private test bus only when EVERY entry (';'-separated) is either unix:path=<a socket under `dir`> (percent-escapes
// decoded, dots resolved: "%2Frun%2F..." and "dir/../x" do not pass) or tcp on loopback; nothing else (abstract, runtime=, systemd:,
// launchd:, a real socket) is accepted. `dir` is the scratch directory of the test (GF_TEST_BUS_DIR).
bool isPrivateTestBus(const QString &address, const QString &dir)
{
    if (address.isEmpty() || dir.isEmpty())
        return false;
    const QString root = QDir::cleanPath(dir);
    const QStringList entries = address.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    if (entries.isEmpty())
        return false;
    for (const QString &entry : entries) {
        const int colon = entry.indexOf(QLatin1Char(':'));
        if (colon <= 0)
            return false;
        const QString transport = entry.left(colon);
        QMap<QString, QString> kv;
        for (const QString &pair : entry.mid(colon + 1).split(QLatin1Char(','), Qt::SkipEmptyParts)) {
            const int eq = pair.indexOf(QLatin1Char('='));
            if (eq <= 0)
                return false;
            kv.insert(pair.left(eq), QString::fromUtf8(QByteArray::fromPercentEncoding(pair.mid(eq + 1).toUtf8())));
        }
        if (transport == QLatin1String("unix")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("path") && it.key() != QLatin1String("guid"))
                    return false;
            const QString path = kv.value(QStringLiteral("path"));
            if (path.isEmpty() || !path.startsWith(QLatin1Char('/')) || !QDir::cleanPath(path).startsWith(root + QLatin1Char('/')))
                return false;
        } else if (transport == QLatin1String("tcp")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("host") && it.key() != QLatin1String("port") && it.key() != QLatin1String("family") && it.key() != QLatin1String("guid"))
                    return false;
            const QString host = kv.value(QStringLiteral("host"));
            if (host != QLatin1String("127.0.0.1") && host != QLatin1String("localhost") && host != QLatin1String("::1"))
                return false;
        } else {
            return false;
        }
    }
    return true;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QString address = qEnvironmentVariable("DBUS_SYSTEM_BUS_ADDRESS");
    if (qEnvironmentVariable("GF_TEST_BUS") != QLatin1String("1") || !isPrivateTestBus(address, qEnvironmentVariable("GF_TEST_BUS_DIR"))) {
        std::fprintf(stderr, "probe: refusing to run on '%s': only a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR, DBUS_SYSTEM_BUS_ADDRESS)\n", qPrintable(address));
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
    if (args.first() == QLatin1String("close-midjob")) {
        // The window closes while a slow service has not answered: the Backend's own machinery (busjobs.h, qtbuscaller.h) on the
        // real connection. No callback may run afterwards, the destructor must not wait for the service, and the stuck job is
        // abandoned (the app's default for that is _Exit(0); here a flag, then the same exit).
        SystemBusConnection connection;
        std::atomic<int> callbacks{0};
        std::atomic<bool> abandoned{false};
        QElapsedTimer closing;
        {
            BusJobs jobs([&connection] { return connection.caller(); }, 200, [&abandoned] { abandoned = true; });
            jobs.start(
                [](BusCaller &bus, QString *) { return runAction(bus, {{"op", "bt.connect"}, {"mac", "11:22:33:44:55:66"}, {"connect", true}}); },
                [&callbacks](const QString &, const QString &) { ++callbacks; }, 30000);
            QElapsedTimer wait;
            wait.start();
            while (wait.elapsed() < 500)
                QCoreApplication::processEvents(QEventLoop::AllEvents, 20); // the call is on the wire, the service is asleep
            closing.start();
        }
        const qint64 ms = closing.elapsed();
        QElapsedTimer after;
        after.start();
        while (after.elapsed() < 300)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        const bool ok = callbacks.load() == 0 && abandoned.load() && ms < 1500;
        std::printf("close-midjob: destructor %lld ms, abandoned=%d, callbacks after=%d: %s\n", static_cast<long long>(ms), abandoned.load() ? 1 : 0, callbacks.load(), ok ? "ok" : "FAILED");
        std::fflush(nullptr);
        std::_Exit(ok ? 0 : 1);
    }
    const QString verb = args.first();
    const QVariantMap op = verb == QLatin1String("act") && args.size() == 2 ? QJsonDocument::fromJson(args.at(1).toUtf8()).object().toVariantMap() : QVariantMap();
    const bool session = verb == QLatin1String("units-state") || sessionAction(op);
    const QString sessionAddress = qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS");
    if (session && !isPrivateTestBus(sessionAddress, qEnvironmentVariable("GF_TEST_BUS_DIR"))) {
        std::fprintf(stderr, "probe: refusing the session bus '%s': only a private test bus\n", qPrintable(sessionAddress));
        return 2;
    }
    const QStringList ownDirs{QDir::cleanPath(qEnvironmentVariable("GF_TEST_BUS_DIR") + QStringLiteral("/units"))};
    // QDBusConnection::systemBus() takes DBUS_SYSTEM_BUS_ADDRESS, as the app does; sessionBus() DBUS_SESSION_BUS_ADDRESS.
    const QDBusConnection connection = session ? QDBusConnection::sessionBus() : QDBusConnection::systemBus();
    if (!connection.isConnected())
        std::fprintf(stderr, "probe: not connected to %s: %s: %s\n", qPrintable(session ? sessionAddress : address), qPrintable(connection.lastError().name()), qPrintable(connection.lastError().message()));
    QtBusCaller real(connection);
    GuardedCaller bus(real, dev);
    const QMap<QString, StateResult (*)(BusCaller &)> states{{QStringLiteral("host-state"), hostState}, {QStringLiteral("time-state"), timeState},
                                                             {QStringLiteral("time-zones"), timeZones}, {QStringLiteral("locale-state"), localeState},
                                                             {QStringLiteral("net-state"), networkState}, {QStringLiteral("power-state"), powerState}};
    if (states.contains(verb) || verb == QLatin1String("units-state")) {
        const StateResult r = verb == QLatin1String("units-state") ? userUnits(bus, ownDirs) : states.value(verb)(bus);
        if (!r.ok) {
            std::printf("failed: %s\n", qPrintable(r.error));
            return 1;
        }
        std::printf("%s\n", QJsonDocument(r.json).toJson(QJsonDocument::Compact).constData());
        return 0;
    }
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
        const QString reason = runAction(bus, op, ownDirs);
        if (!reason.isEmpty()) {
            std::printf("failed: %s\n", qPrintable(reason));
            return 1;
        }
        std::printf("ok\n");
        return 0;
    }
    return 2;
}
