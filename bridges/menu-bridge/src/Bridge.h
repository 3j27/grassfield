#pragma once

// grassfield-menu-bridge core: the menu/1 socket for grassfield-shell, the gated registrar, and one MenuClient per
// window the shell opened (ADR-0008, docs/specs/menu-bridge.md).
//
// - One shell connection at a time; extra connections get an error and are closed.
// - com.canonical.AppMenu.Registrar is owned only while the connected shell's latest hello says "appmenu": true
//   (the plugin advertises appmenu and the menu bar renders bridge menus). It is released on hello "appmenu": false
//   and when the shell disconnects, so applications started meanwhile keep their in-window menus.
// - open: (service, path) come from the plugin's appmenu event, relayed by the shell with the registering client's
//   pid. The bridge resolves the bus name's owner and accepts the pair only if
//   org.freedesktop.DBus.GetConnectionUnixProcessID(owner) equals that pid (a client naming another app's bus name
//   is refused). It then talks to the unique name only.
// - The bridge executes nothing: it only sends DBusMenu GetLayout / AboutToShow / Event calls.

#include "DBusObjects.h"
#include "MenuClient.h"
#include "Penalties.h"
#include "Protocol.h"

#include <QByteArray>
#include <QDBusConnection>
#include <QHash>
#include <QLocalServer>
#include <QObject>
#include <QPointer>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

class QLocalSocket;

namespace gf::menubridge {

    class Bridge : public QObject {
      public:
        Bridge(const QDBusConnection& bus, QString socketPath, QObject* parent = nullptr);
        ~Bridge() override;

        Bridge(const Bridge&)            = delete;
        Bridge& operator=(const Bridge&) = delete;

        // Listens on the socket (directory 0700, socket 0600). False with *error set when it cannot.
        bool        listen(QString* error);
        // Releases the registrar, drops every menu and removes the socket.
        void        stop();

        QVariantMap status() const;

      private:
        void    onNewConnection();
        void    onReadyRead();
        void    onClientGone();
        void    handle(const ShellMessage& msg);
        void    hello(bool appmenu);
        void    open(const ShellMessage& msg);
        void    verified(const ShellMessage& msg, quint64 token, const QString& owner);
        void    close(const QString& window);
        // Hostile or broken applications (Penalties.h): refusals are keyed by the application's identity (app scope,
        // executable, script). Every call sent to an application is recorded as in flight in the state file until its
        // reply was handled (refreshed every penalty::kHeartbeatMs while one is open). A restarted bridge blames an
        // application only for ONE fresh call in flight at the crash; every crash, blamed or not, is counted: after
        // penalty::kMaxCrashes within penalty::kCrashWindowSec the bridge gives up (degraded: no registrar, no menus).
        void    recordFailure(const QString& window, const QString& code);
        void    beginCall(const QString& id);
        void    endCall(const QString& id, int n = 1);
        void    saveState();
        void    heartbeat();
        void    loadState();
        void    dropAll();
        void    setRegistrar(bool wanted);
        void    send(const QByteArray& line);
        void    sendStatus();
        void    sendError(const QString& window, const QString& code, const QString& message);
        QString state() const;
        QString stateFile() const {
            return m_socketPath + QStringLiteral(".state");
        }

        QDBusConnection                m_bus;
        QString                        m_socketPath;
        QLocalServer                   m_server;
        QPointer<QLocalSocket>         m_client;
        QByteArray                     m_buffer;
        int                            m_badLines  = 0;
        bool                           m_appmenu   = false; // latest hello
        bool                           m_registrar = false;
        bool                           m_registrarBusy = false;
        RegistrarObject                m_registrarObject;

        struct SOpened {
            QString service; // as requested by the shell
            QString path;
            qint64  pid = 0;
        };
        QHash<QString, MenuClient*> m_menus;   // window -> client (owned)
        QHash<QString, SOpened>     m_opened;  // window -> request of m_menus[window]
        QHash<QString, quint32>     m_revision;
        QStringList                 m_order;   // windows, least recently opened first
        QHash<QString, quint64>     m_pending; // window -> token of the open being verified
        quint64                     m_token = 0;
        bool                        m_stateOwned = false; // loadState ran: this instance is the one bridge that may write the state file

        PenaltyBook                 m_penalties;
        struct Calls {
            int     count     = 0;
            qint64  startedMs = 0; // monotonic clock, start of the oldest call in flight
        };
        QHash<QString, Calls>       m_calls;     // identity -> calls in flight (mirrored in the state file)
        QTimer                      m_heartbeat; // rewrites the state while calls are in flight (their age)
        bool                        m_running  = true;  // false after stop(): the state says "stopped cleanly"
        bool                        m_degraded = false; // gave up after too many unattributed crashes
        QHash<QString, QString>     m_keyOf;    // window -> identity
    };

} // namespace gf::menubridge
