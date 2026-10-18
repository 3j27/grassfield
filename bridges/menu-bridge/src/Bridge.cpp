#include "Bridge.h"

#include "Log.h"
#include "Safety.h"

#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QFile>
#include <QLocalSocket>
#include <QTimer>

#include <algorithm>
#include <sys/stat.h>
#include <time.h>

#include <utility>

namespace gf::menubridge {

    namespace {
        constexpr int       kDBusTimeoutMs   = 2000;
        constexpr qsizetype kMaxPendingWrite = 16 * 1024 * 1024; // a shell that stops reading is dropped
        constexpr int       kCallTimeoutMs   = 3000;             // MenuClient::kCallTimeoutMs (+ slack below)

        qint64 monotonicMs() {
            timespec ts{};
            ::clock_gettime(CLOCK_MONOTONIC, &ts);
            return static_cast<qint64>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }

        QDBusMessage busCall(const char* method, const QString& name) {
            QDBusMessage msg = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
                                                              QLatin1String(method));
            msg << name;
            return msg;
        }
    } // namespace

    Bridge::Bridge(const QDBusConnection& bus, QString socketPath, QObject* parent) : QObject(parent), m_bus(bus), m_socketPath(std::move(socketPath)) {
        m_server.setSocketOptions(QLocalServer::UserAccessOption);
        m_server.setMaxPendingConnections(2);
        connect(&m_server, &QLocalServer::newConnection, this, [this] { onNewConnection(); });
        m_heartbeat.setInterval(penalty::kHeartbeatMs);
        connect(&m_heartbeat, &QTimer::timeout, this, [this] { heartbeat(); });
    }

    Bridge::~Bridge() {
        stop();
    }

    bool Bridge::listen(QString* error) {
        if (!fitsSocketPath(m_socketPath)) {
            *error = QStringLiteral("socket path too long or empty: %1").arg(m_socketPath);
            return false;
        }
        if (const QString dirError = prepareSocketDirectory(m_socketPath); !dirError.isEmpty()) {
            *error = dirError;
            return false;
        }
        const QByteArray local = QFile::encodeName(m_socketPath);
        struct stat      st{};
        if (::lstat(local.constData(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode)) {
                *error = QStringLiteral("%1 exists and is not a socket").arg(m_socketPath);
                return false;
            }
            QLocalSocket probe;
            probe.connectToServer(m_socketPath);
            if (probe.waitForConnected(300)) {
                *error = QStringLiteral("another grassfield-menu-bridge listens on %1").arg(m_socketPath);
                return false;
            }
            QLocalServer::removeServer(m_socketPath); // stale socket of a previous run
        }
        // Only now: a second instance that found the live bridge above must not touch its state file.
        loadState();
        if (!m_server.listen(m_socketPath)) {
            *error = QStringLiteral("cannot listen on %1: %2").arg(m_socketPath, m_server.errorString());
            return false;
        }
        ::chmod(local.constData(), 0600);
        log(QStringLiteral("listening on %1 (standby until the shell says hello with appmenu)").arg(m_socketPath));
        return true;
    }

    void Bridge::stop() {
        setRegistrar(false);
        dropAll();
        m_calls.clear(); // a clean stop leaves nothing in flight
        m_heartbeat.stop();
        m_running = false;
        saveState(); // "run 0": the next start knows this was not a crash
        if (m_client) {
            m_client->disconnect(this);
            m_client->abort();
            m_client = nullptr;
        }
        if (m_server.isListening()) {
            m_server.close(); // removes the socket file
            log(QStringLiteral("stopped"));
        }
    }

    QVariantMap Bridge::status() const {
        return {
            {QStringLiteral("state"), state()},
            {QStringLiteral("registrar"), m_registrar},
            {QStringLiteral("degraded"), m_degraded},
            {QStringLiteral("shell"), !m_client.isNull()},
            {QStringLiteral("menus"), static_cast<uint>(m_menus.size())},
        };
    }

    QString Bridge::state() const {
        if (m_degraded)
            return QStringLiteral("degraded");
        if (m_registrar)
            return QStringLiteral("active");
        return m_appmenu && m_registrarBusy ? QStringLiteral("busy") : QStringLiteral("standby");
    }

    void Bridge::onNewConnection() {
        while (QLocalSocket* s = m_server.nextPendingConnection()) {
            if (m_client) {
                s->write(errorMessage(QString(), QStringLiteral("busy"), QStringLiteral("another shell is connected")));
                s->flush();
                s->disconnectFromServer();
                connect(s, &QLocalSocket::disconnected, s, &QObject::deleteLater);
                continue;
            }
            m_client = s;
            m_buffer.clear();
            m_badLines = 0;
            connect(s, &QLocalSocket::readyRead, this, [this] { onReadyRead(); });
            connect(s, &QLocalSocket::disconnected, this, [this, s] {
                if (s == m_client)
                    onClientGone();
                s->deleteLater();
            });
            log(QStringLiteral("shell connected"));
            sendStatus();
        }
    }

    void Bridge::onReadyRead() {
        if (!m_client)
            return;
        m_buffer += m_client->readAll();
        while (m_client) {
            const qsizetype nl = m_buffer.indexOf('\n');
            if (nl < 0)
                break;
            const QByteArray line = m_buffer.left(nl).trimmed();
            m_buffer.remove(0, nl + 1);
            if (line.isEmpty())
                continue;
            QString    error;
            const auto msg = parseShellMessage(line, &error);
            if (!msg) {
                sendError(QString(), QStringLiteral("bad-request"), error);
                if (++m_badLines > limits::kBadLines) {
                    log(QStringLiteral("too many invalid requests: closing the shell connection"));
                    m_client->disconnectFromServer();
                }
                continue;
            }
            handle(*msg);
        }
        if (m_client && m_buffer.size() > limits::kShellLine) {
            sendError(QString(), QStringLiteral("bad-request"), QStringLiteral("too-long"));
            log(QStringLiteral("request line over %1 bytes: closing the shell connection").arg(limits::kShellLine));
            m_buffer.clear();
            m_client->disconnectFromServer();
        }
    }

    void Bridge::onClientGone() {
        log(QStringLiteral("shell disconnected"));
        m_client  = nullptr;
        m_appmenu = false;
        m_buffer.clear();
        setRegistrar(false);
        dropAll();
    }

    void Bridge::handle(const ShellMessage& msg) {
        switch (msg.type) {
            case ShellMessage::Type::Hello: hello(msg.appmenu); return;
            case ShellMessage::Type::Open: open(msg); return;
            case ShellMessage::Type::Close: close(msg.window); return;
            case ShellMessage::Type::AboutToShow: {
                MenuClient* c = m_menus.value(msg.window);
                if (!c || !c->aboutToShow(msg.id))
                    sendError(msg.window, QStringLiteral("unknown-item"), QStringLiteral("no submenu %1 in this window's menu").arg(msg.id));
                return;
            }
            case ShellMessage::Type::Activate: {
                MenuClient* c = m_menus.value(msg.window);
                if (!c || !c->activate(msg.id)) {
                    sendError(msg.window, QStringLiteral("unknown-item"), QStringLiteral("no active item %1 in this window's menu").arg(msg.id));
                    return;
                }
                log(QStringLiteral("window %1: activate item %2 of %3").arg(msg.window).arg(msg.id).arg(c->service()));
                return;
            }
        }
    }

    void Bridge::hello(bool appmenu) {
        m_appmenu = appmenu;
        setRegistrar(appmenu);
        sendStatus();
    }

    void Bridge::open(const ShellMessage& msg) {
        if (m_degraded) {
            // Gave up (too many crashes the bridge could not attribute): no menu is served, the shell shows T0.
            sendError(msg.window, QStringLiteral("backoff"), QStringLiteral("the menu bridge gave up after repeated unexplained crashes; menus are not served until it is restarted later"));
            return;
        }
        // The same request as the open menu: send its menu again.
        if (MenuClient* c = m_menus.value(msg.window)) {
            const SOpened& o = m_opened.value(msg.window);
            if (o.service == msg.service && o.path == msg.path && o.pid == msg.pid) {
                m_pending.remove(msg.window);
                if (c->ready())
                    send(menuMessage(msg.window, ++m_revision[msg.window], c->items()));
                return;
            }
        }
        const quint64 token = ++m_token;
        m_pending.insert(msg.window, token);

        // Step 2: the owner's process must be the Wayland client that registered the menu.
        auto checkPid = [this, msg, token](const QString& owner) {
            auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(busCall("GetConnectionUnixProcessID", owner), kDBusTimeoutMs), this);
            connect(w, &QDBusPendingCallWatcher::finished, this, [this, msg, token, owner](QDBusPendingCallWatcher* call) {
                call->deleteLater();
                if (m_pending.value(msg.window) != token)
                    return; // superseded or closed meanwhile
                const QDBusMessage reply = call->reply();
                if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
                    // Typically the application left the bus meanwhile (window closing).
                    m_pending.remove(msg.window);
                    log(QStringLiteral("window %1: no process for %2: %3").arg(msg.window, owner, reply.errorName()));
                    sendError(msg.window, QStringLiteral("no-owner"), QStringLiteral("%1 has no owner on the bus").arg(owner));
                    return;
                }
                const qint64 pid = reply.arguments().at(0).toLongLong();
                if (pid != msg.pid) {
                    m_pending.remove(msg.window);
                    log(QStringLiteral("window %1: refused %2 %3: bus name owned by pid %4, window client is pid %5").arg(msg.window, msg.service, msg.path).arg(pid).arg(msg.pid));
                    sendError(msg.window, QStringLiteral("pid-mismatch"), QStringLiteral("the bus name does not belong to the window's process"));
                    return;
                }
                verified(msg, token, owner);
            });
        };

        // Step 1: resolve a well-known name to its current unique owner (the bridge then talks to that one only).
        if (msg.service.startsWith(u':')) {
            checkPid(msg.service);
            return;
        }
        auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(busCall("GetNameOwner", msg.service), kDBusTimeoutMs), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, msg, token, checkPid](QDBusPendingCallWatcher* call) {
            call->deleteLater();
            if (m_pending.value(msg.window) != token)
                return;
            const QDBusMessage reply = call->reply();
            const QString      owner = reply.type() == QDBusMessage::ReplyMessage && !reply.arguments().isEmpty() ? reply.arguments().at(0).toString() : QString();
            if (!isValidBusName(owner) || !owner.startsWith(u':')) {
                m_pending.remove(msg.window);
                sendError(msg.window, QStringLiteral("no-owner"), QStringLiteral("%1 has no owner on the bus").arg(msg.service));
                return;
            }
            checkPid(owner);
        });
    }

    void Bridge::verified(const ShellMessage& msg, quint64 token, const QString& owner) {
        if (m_pending.value(msg.window) != token)
            return;
        close(msg.window); // a previous menu of this window
        // The application's identity as the bridge observes it (the pid was checked against the bus name's owner).
        const QString key = appIdentity(msg.pid);
        if (QString why; m_penalties.refused(key, &why)) {
            m_pending.remove(msg.window);
            log(QStringLiteral("window %1: %2 %3 (pid %4, %5) refused: %6").arg(msg.window, owner, msg.path).arg(msg.pid).arg(key, why));
            sendError(msg.window, QStringLiteral("backoff"), why);
            return;
        }
        while (m_menus.size() >= limits::kOpenWindows && !m_order.isEmpty())
            close(m_order.front());

        auto* c = new MenuClient(m_bus, msg.window, owner, msg.path, this);
        m_menus.insert(msg.window, c);
        m_opened.insert(msg.window, SOpened{.service = msg.service, .path = msg.path, .pid = msg.pid});
        m_order.append(msg.window);
        m_keyOf.insert(msg.window, key);
        connect(c, &MenuClient::callBegun, this, [this, key] { beginCall(key); });
        connect(c, &MenuClient::callEnded, this, [this, key] { endCall(key); });
        connect(c, &MenuClient::menuChanged, this, [this, c, key](const QString& window) {
            if (m_menus.value(window) != c)
                return;
            m_penalties.delivered(key);
            send(menuMessage(window, ++m_revision[window], c->items()));
        });
        connect(c, &MenuClient::failed, this, [this, c](const QString& window, const QString& code, const QString& message) {
            if (m_menus.value(window) != c)
                return;
            recordFailure(window, code);
            sendError(window, code, message);
            close(window);
        });
        log(QStringLiteral("window %1: menu %2 %3 (pid %4, %5) opened").arg(msg.window, owner, msg.path).arg(msg.pid).arg(key));
        c->start();
    }

    void Bridge::recordFailure(const QString& window, const QString& code) {
        const QString key = m_keyOf.value(window);
        if (key.isEmpty())
            return;
        if (code == QLatin1String("gone"))
            m_penalties.leftCleanly(key);
        else if (code == QLatin1String("oversized"))
            m_penalties.record(key, Offence::Oversized);
        else if (code == QLatin1String("layout-failed"))
            m_penalties.record(key, Offence::LayoutFailed);
        saveState();
    }

    void Bridge::beginCall(const QString& id) {
        Calls& c = m_calls[id];
        if (c.count++ == 0)
            c.startedMs = monotonicMs();
        if (!m_heartbeat.isActive())
            m_heartbeat.start();
        saveState(); // written before the call leaves: a crash while it is outstanding is attributed
    }

    void Bridge::endCall(const QString& id, int n) {
        const auto it = m_calls.find(id);
        if (it == m_calls.end())
            return;
        it->count -= n;
        if (it->count <= 0)
            m_calls.erase(it);
        if (m_calls.isEmpty())
            m_heartbeat.stop();
        saveState();
    }

    void Bridge::heartbeat() {
        if (m_calls.isEmpty()) {
            m_heartbeat.stop();
            return;
        }
        saveState(); // refreshes the age of the calls in flight
    }

    void Bridge::saveState() {
        if (!m_stateOwned)
            return; // an instance that never passed the singleton probe must not overwrite the live bridge's state
        QList<InflightCall> inflight;
        const qint64        now = monotonicMs();
        for (auto it = m_calls.cbegin(); it != m_calls.cend(); ++it)
            inflight.append({it.key(), it->count, std::max<qint64>(0, now - it->startedMs)});
        if (!writeStateFile(stateFile(), m_penalties.serialize(inflight, bootId(), m_running)))
            log(QStringLiteral("cannot write %1: crash attribution is degraded").arg(stateFile()));
    }

    void Bridge::loadState() {
        // A previous run that did not stop cleanly (killed by the memory limit, crashed) is attributed ONLY when
        // exactly one fresh call to one application was in flight: that application is refused (Penalties.h).
        // Otherwise the crash is unattributed (unsolicited traffic, several calls, a stale call): nobody is refused,
        // it is only counted. Every crash is counted, and after penalty::kMaxCrashes of them within
        // penalty::kCrashWindowSec the bridge gives up (degraded). The file is rewritten at once with the outcome.
        QByteArray data;
        QString    why;
        if (readStateFile(stateFile(), &data, &why)) {
            CrashOutcome outcome;
            if (!m_penalties.load(data, bootId(), &why, &outcome)) {
                log(QStringLiteral("ignored %1: %2").arg(stateFile(), why));
            } else if (!outcome.culprit.isEmpty()) {
                log(QStringLiteral("a previous run died while a call to \"%1\" was in flight: refused (crash %2 of %3)")
                        .arg(displayIdentity(outcome.culprit))
                        .arg(outcome.crashes)
                        .arg(penalty::kMaxCrashes));
            } else if (outcome.crashed) {
                log(QStringLiteral("a previous run died without a single fresh call in flight: unattributed crash %1 of %2, nobody is refused")
                        .arg(outcome.crashes)
                        .arg(penalty::kMaxCrashes));
            }
        } else if (!why.isEmpty()) {
            log(QStringLiteral("ignored %1: %2").arg(stateFile(), why));
            QFile::remove(stateFile()); // unlink never follows a symlink
        }
        if (m_penalties.degraded()) {
            m_degraded = true;
            log(QStringLiteral("gave up: %1 crashes within the last hour; the registrar is not owned and no menu is served (T0 menus)").arg(m_penalties.crashes()));
        }
        m_stateOwned = true; // past the singleton probe (listen): this instance now owns the file
        saveState();
    }

    void Bridge::close(const QString& window) {
        const QString key = m_keyOf.take(window);
        m_pending.remove(window);
        if (MenuClient* c = m_menus.take(window)) {
            c->disconnect(this);
            // Replies still on their way keep the application marked until they arrived or timed out.
            if (const int n = c->outstanding(); n > 0 && !key.isEmpty())
                QTimer::singleShot(kCallTimeoutMs + 1000, this, [this, key, n] { endCall(key, n); });
            c->deleteLater();
        }
        m_opened.remove(window);
        m_revision.remove(window);
        m_order.removeAll(window);
    }

    void Bridge::dropAll() {
        const QStringList windows = m_menus.keys();
        for (const QString& w : windows)
            close(w);
        m_pending.clear();
    }

    void Bridge::setRegistrar(bool wanted) {
        if (wanted == m_registrar) {
            if (!wanted)
                m_registrarBusy = false;
            return;
        }
        if (wanted && m_degraded)
            return; // gave up: never owns the registrar, applications keep their in-window menus
        const QString service = QLatin1String(kRegistrarService);
        const QString path    = QLatin1String(kRegistrarPath);
        if (!wanted) {
            if (m_bus.interface())
                m_bus.interface()->unregisterService(service);
            m_bus.unregisterObject(path);
            m_registrar     = false;
            m_registrarBusy = false;
            log(QStringLiteral("released %1").arg(service));
            return;
        }
        if (!m_bus.interface() || !m_bus.registerVirtualObject(path, &m_registrarObject, QDBusConnection::SingleNode)) {
            m_registrarBusy = true;
            log(QStringLiteral("cannot export %1").arg(path));
            return;
        }
        const auto reply = m_bus.interface()->registerService(service, QDBusConnectionInterface::DontQueueService, QDBusConnectionInterface::DontAllowReplacement);
        if (!reply.isValid() || reply.value() != QDBusConnectionInterface::ServiceRegistered) {
            m_bus.unregisterObject(path);
            m_registrarBusy = true;
            log(QStringLiteral("%1 is owned by another process: staying in standby").arg(service));
            sendError(QString(), QStringLiteral("registrar-busy"), QStringLiteral("%1 is owned by another process").arg(service));
            return;
        }
        m_registrar     = true;
        m_registrarBusy = false;
        log(QStringLiteral("owning %1 (the shell reported the appmenu feature)").arg(service));
    }

    void Bridge::send(const QByteArray& line) {
        if (!m_client)
            return;
        if (m_client->bytesToWrite() > kMaxPendingWrite) {
            log(QStringLiteral("the shell does not read its socket: closing the connection"));
            m_client->abort();
            return;
        }
        m_client->write(line);
    }

    void Bridge::sendStatus() {
        send(statusMessage(state(), m_registrar));
    }

    void Bridge::sendError(const QString& window, const QString& code, const QString& message) {
        send(errorMessage(window, code, message));
    }

} // namespace gf::menubridge
