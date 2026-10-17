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
#include "Protocol.h"

#include <QByteArray>
#include <QDBusConnection>
#include <QHash>
#include <QLocalServer>
#include <QObject>
#include <QPointer>
#include <QStringList>
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
        void    dropAll();
        void    setRegistrar(bool wanted);
        void    send(const QByteArray& line);
        void    sendStatus();
        void    sendError(const QString& window, const QString& code, const QString& message);
        QString state() const;

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
    };

} // namespace gf::menubridge
