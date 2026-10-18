// SPDX-License-Identifier: MIT
// huge-menu: a hostile DBusMenu application and a stand-in for grassfield-shell, for the menu bridge's memory tests
// (tests/integration/menu_bridge_memory.sh). TEST FIXTURE ONLY.
//
// It owns --service on the session bus and serves com.canonical.dbusmenu at /MenuBar/1: GetLayout answers a layout of
// --items children whose label is --label-kb kB. Then it plays the shell on the bridge socket: for every one of
// --windows rounds it connects (retrying, so a restarted bridge is found), sends hello and an open request for this
// process, and prints what the bridge answers. With --kill-pid it SIGKILLs that process (the bridge) on the
// --kill-on'th GetLayout (default 1), to emulate a kill by the memory limit. With --emit-updates it sends a
// LayoutUpdated signal after answering the first GetLayout, so the bridge re-reads the layout (the "small first
// layout, hostile re-read" crash loop). Before every round after the first it waits until the bridge reports no
// shell connection (org.grassfield.MenuBridge1.Status "shell" false), so a round never races the bridge's handling of
// the previous disconnect.
//
// Hostile unsolicited traffic (the counter-review's scenarios): --spam-mb N sends the bridge a directed method call of
// N MB (org.grassfield.MenuBridge1, a junk interface) --spam-times T times, each time once the bridge answers its
// Status after a (re)start and waiting until the bridge died; --spam-after-ms delays the first one. --huge-update-mb N
// sends a LayoutUpdated signal of N MB (the signal the bridge subscribed to) after the first GetLayout answer.
// --reply-delay-ms D answers every GetLayout D ms late (a slow but honest application).
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
#include <QTimer>
#include <QVariantMap>

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <unistd.h>

namespace {
    int   gItems     = 1500;
    int   gLabelKb   = 20;
    int   gGetLayout = 0;
    pid_t gKillPid   = 0;
    int   gKillOn    = 1;
    bool  gEmitUpdates = false;
    int   gSpamMb      = 0;
    int   gSpamTimes   = 1;
    int   gSpamAfterMs = 0;
    int   gHugeUpdateMb = 0;
    int   gReplyDelayMs = 0;

    // libdbus caps one array at 64 MB: a message of `mb` MB carries several byte arrays of at most 32 MB.
    void addPayload(QDBusMessage& msg, int mb) {
        for (int left = mb; left > 0; left -= 32)
            msg << QByteArray(static_cast<qsizetype>(std::min(left, 32)) * 1024 * 1024, 'x');
    }

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
            if (gKillPid > 0 && gGetLayout == gKillOn) {
                ::kill(gKillPid, SIGKILL);
                return true; // the caller is dead: no reply
            }
            const QDBusMessage reply = msg.createReply(m_reply.toList());
            if (gReplyDelayMs > 0) {
                const QDBusConnection c = conn;
                QTimer::singleShot(gReplyDelayMs, [c, reply] { c.send(reply); });
            } else
                conn.send(reply);
            if ((gEmitUpdates || gHugeUpdateMb > 0) && gGetLayout == 1) {
                const QDBusConnection c = conn;
                QTimer::singleShot(150 + gReplyDelayMs, [c] {
                    QDBusMessage sig = QDBusMessage::createSignal(QStringLiteral("/MenuBar/1"), QStringLiteral("com.canonical.dbusmenu"), QStringLiteral("LayoutUpdated"));
                    sig << QVariant::fromValue<uint>(2) << QVariant::fromValue<int>(0);
                    if (gHugeUpdateMb > 0)
                        addPayload(sig, gHugeUpdateMb);
                    c.send(sig);
                });
            }
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

    // The bridge's own view of the shell connection: 1 connected, 0 not, -1 the bridge does not answer (down).
    int bridgeHasShell(QDBusConnection& conn) {
        QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.grassfield.MenuBridge1"), QStringLiteral("/org/grassfield/MenuBridge1"), QStringLiteral("org.grassfield.MenuBridge1"),
                                                           QStringLiteral("Status"));
        const QDBusMessage reply = conn.call(call, QDBus::Block, 500);
        if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty())
            return -1;
        const QVariantMap status = qdbus_cast<QVariantMap>(reply.arguments().at(0).value<QDBusArgument>());
        return status.value(QStringLiteral("shell")).toBool() ? 1 : 0;
    }

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
    for (qsizetype i = 1; i < args.size(); ++i) {
        if (args.at(i) == QLatin1String("--emit-updates")) {
            gEmitUpdates = true;
            continue;
        }
        if (i + 1 >= args.size())
            break;
        const QString& a = args.at(i);
        const QString& v = args.at(++i);
        if (a == QLatin1String("--spam-mb"))
            gSpamMb = v.toInt();
        else if (a == QLatin1String("--spam-times"))
            gSpamTimes = v.toInt();
        else if (a == QLatin1String("--spam-after-ms"))
            gSpamAfterMs = v.toInt();
        else if (a == QLatin1String("--huge-update-mb"))
            gHugeUpdateMb = v.toInt();
        else if (a == QLatin1String("--reply-delay-ms"))
            gReplyDelayMs = v.toInt();
        else if (a == QLatin1String("--items"))
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
        else if (a == QLatin1String("--kill-on"))
            gKillOn = v.toInt();
        else if (a == QLatin1String("--service"))
            service = v;
    }
    if (socket.isEmpty()) {
        std::fprintf(stderr, "usage: huge-menu --socket PATH [--items N] [--label-kb K] [--windows W] [--gap-ms MS] [--kill-pid PID] [--kill-on N] [--emit-updates] [--service NAME]\n");
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

    if (gSpamMb > 0) {
        pump(gSpamAfterMs);
        QDBusMessage junk = QDBusMessage::createMethodCall(QStringLiteral("org.grassfield.MenuBridge1"), QStringLiteral("/org/grassfield/MenuBridge1"), QStringLiteral("org.grassfield.Junk1"),
                                                           QStringLiteral("Spam"));
        addPayload(junk, gSpamMb);
        for (int t = 1; t <= gSpamTimes; ++t) {
            QElapsedTimer up;
            up.start();
            while (bridgeHasShell(conn) < 0 && up.elapsed() < 20000)
                pump(100);
            std::printf("huge-menu: spam #%d: %d MB call to the bridge\n", t, gSpamMb);
            std::fflush(stdout);
            conn.send(junk);
            QElapsedTimer down;
            down.start();
            while (bridgeHasShell(conn) >= 0 && down.elapsed() < 10000)
                pump(100);
            std::printf("huge-menu: spam #%d: bridge %s\n", t, bridgeHasShell(conn) < 0 ? "went down" : "survived");
            std::fflush(stdout);
        }
    }

    for (int round = 1; round <= windows; ++round) {
        if (round > 1) {
            // The previous round's connection must be handled (the bridge accepts one shell at a time).
            QElapsedTimer settle;
            settle.start();
            while (bridgeHasShell(conn) == 1 && settle.elapsed() < 10000)
                pump(20);
        }
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
            if (buffer.contains("\"type\":\"error\""))
                break; // refused or failed: nothing more to wait for
        }
        for (const QByteArray& line : buffer.split('\n')) {
            if (!line.isEmpty() && line.contains("\"type\":\"status\""))
                std::printf("huge-menu: round %d: status %s\n", round, line.left(200).constData());
            else if (!line.isEmpty() && line.contains("\"type\":\"error\""))
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
