// SPDX-License-Identifier: MIT
// huge-menu: a hostile DBusMenu application and a stand-in for grassfield-shell, for the menu bridge's memory tests
// (tests/integration/menu_bridge_memory.sh). TEST FIXTURE ONLY.
//
// It owns --service on the session bus and serves com.canonical.dbusmenu at /MenuBar/1: GetLayout answers a layout of
// --items children whose label is --label-kb kB. Then it plays the shell on the bridge socket: for every one of
// --windows rounds it connects (retrying, so a restarted bridge is found), sends hello and an open request for this
// process, and prints what the bridge answers. With --kill-pid it SIGKILLs that process (the bridge) on the first
// GetLayout, to emulate a kill by the memory limit.
//
// Refuses to run unless DBUS_SESSION_BUS_ADDRESS is a private /tmp/dbus-* bus (never the owner's session bus).
//
// Build: tests/fixtures/build.sh huge-menu (g++ + pkg-config Qt6DBus, Qt6Network; no moc needed).

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QDBusVirtualObject>
#include <QElapsedTimer>
#include <QLocalSocket>
#include <QMetaType>
#include <QStringList>

#include <csignal>
#include <cstdio>
#include <unistd.h>

namespace {
    int   gItems     = 1500;
    int   gLabelKb   = 20;
    int   gGetLayout = 0;
    pid_t gKillPid   = 0;

    class HugeMenu : public QDBusVirtualObject {
      public:
        QString introspect(const QString&) const override {
            return {};
        }
        bool handleMessage(const QDBusMessage& msg, const QDBusConnection& conn) override {
            if (msg.member() != QLatin1String("GetLayout")) {
                conn.send(msg.createReply(QVariant(false)));
                return true;
            }
            ++gGetLayout;
            std::printf("huge-menu: GetLayout #%d\n", gGetLayout);
            std::fflush(stdout);
            if (gKillPid > 0 && gGetLayout == 1) {
                ::kill(gKillPid, SIGKILL);
                return true; // the caller is dead: no reply
            }
            conn.send(msg.createReply(m_reply.toList()));
            return true;
        }

        // Built before serving: marshalling tens of thousands of items takes longer than the bridge's call timeout.
        void build() {
            const QString label(gLabelKb * 1024, QLatin1Char('x'));
            QDBusArgument arg;
            arg.beginStructure();
            arg << 0 << QVariantMap{{QStringLiteral("children-display"), QStringLiteral("submenu")}};
            arg.beginArray(qMetaTypeId<QDBusVariant>());
            for (int i = 1; i <= gItems; ++i) {
                QDBusArgument child;
                child.beginStructure();
                child << i << QVariantMap{{QStringLiteral("label"), label}};
                child.beginArray(qMetaTypeId<QDBusVariant>());
                child.endArray();
                child.endStructure();
                arg << QDBusVariant(QVariant::fromValue(child));
            }
            arg.endArray();
            arg.endStructure();
            m_reply = QVariantList{QVariant::fromValue<uint>(1), QVariant::fromValue(arg)};
        }

      private:
        QVariant m_reply;
    };

    void pump(int ms) {
        QElapsedTimer t;
        t.start();
        while (t.elapsed() < ms)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    }
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString    bus = qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS");
    if (!bus.startsWith(QLatin1String("unix:path=/tmp/dbus-"))) {
        std::fprintf(stderr, "huge-menu: refusing: %s is not a private /tmp/dbus-* bus\n", qPrintable(bus));
        return 3;
    }
    QString           service = QStringLiteral("org.grassfield.HugeMenu");
    QString           socket;
    int               windows = 3;
    int               gapMs   = 800;
    const QStringList args    = app.arguments();
    for (qsizetype i = 1; i + 1 < args.size(); i += 2) {
        const QString& a = args.at(i);
        const QString& v = args.at(i + 1);
        if (a == QLatin1String("--items"))
            gItems = v.toInt();
        else if (a == QLatin1String("--label-kb"))
            gLabelKb = v.toInt();
        else if (a == QLatin1String("--socket"))
            socket = v;
        else if (a == QLatin1String("--windows"))
            windows = v.toInt();
        else if (a == QLatin1String("--gap-ms"))
            gapMs = v.toInt();
        else if (a == QLatin1String("--kill-pid"))
            gKillPid = static_cast<pid_t>(v.toInt());
        else if (a == QLatin1String("--service"))
            service = v;
    }
    if (socket.isEmpty()) {
        std::fprintf(stderr, "usage: huge-menu --socket PATH [--items N] [--label-kb K] [--windows W] [--gap-ms MS] [--kill-pid PID] [--service NAME]\n");
        return 2;
    }

    QDBusConnection conn = QDBusConnection::sessionBus();
    HugeMenu        menu;
    menu.build();
    if (!conn.isConnected() || !conn.registerVirtualObject(QStringLiteral("/MenuBar/1"), &menu, QDBusConnection::SingleNode) || !conn.registerService(service)) {
        std::fprintf(stderr, "huge-menu: cannot export the menu on the bus\n");
        return 2;
    }
    std::printf("huge-menu: serving %s /MenuBar/1 items=%d label=%d kB pid=%d\n", qPrintable(service), gItems, gLabelKb, static_cast<int>(::getpid()));
    std::fflush(stdout);

    for (int round = 1; round <= windows; ++round) {
        QLocalSocket  sock;
        QElapsedTimer wait;
        wait.start();
        while (sock.state() != QLocalSocket::ConnectedState && wait.elapsed() < 15000) {
            sock.abort();
            sock.connectToServer(socket);
            if (!sock.waitForConnected(300))
                pump(200);
        }
        if (sock.state() != QLocalSocket::ConnectedState) {
            std::printf("huge-menu: round %d: no bridge socket\n", round);
            continue;
        }
        sock.write("{\"v\":\"menu/1\",\"type\":\"hello\",\"appmenu\":true}\n");
        const QByteArray open = QByteArray("{\"type\":\"open\",\"window\":\"") + QByteArray::number(round + 0x100, 16) + "\",\"service\":\"" + service.toUtf8()
                                + "\",\"path\":\"/MenuBar/1\",\"pid\":" + QByteArray::number(static_cast<int>(::getpid())) + "}\n";
        sock.write(open);
        QElapsedTimer gap;
        gap.start();
        QByteArray buffer;
        while (gap.elapsed() < gapMs && sock.state() == QLocalSocket::ConnectedState) {
            sock.waitForReadyRead(50);
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
            buffer += sock.readAll();
        }
        for (const QByteArray& line : buffer.split('\n')) {
            if (!line.isEmpty() && line.contains("\"type\":\"error\""))
                std::printf("huge-menu: round %d: reply %s\n", round, line.left(200).constData());
            else if (!line.isEmpty() && line.contains("\"type\":\"menu\""))
                std::printf("huge-menu: round %d: reply menu (%lld bytes)\n", round, static_cast<long long>(line.size()));
        }
        std::fflush(stdout);
        sock.disconnectFromServer();
    }
    std::printf("huge-menu: done GetLayout=%d\n", gGetLayout);
    return 0;
}
