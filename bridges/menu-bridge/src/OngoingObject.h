#pragma once

// The D-Bus side of org.grassfield.Ongoing1 (ADR-0052, Ongoing.h): Publish, End and Version at /org/grassfield/Ongoing1,
// served by grassfield-menu-bridge (Quickshell cannot own a bus name or serve methods). This class only talks to the bus;
// every decision is made by the pure parts it holds, unit-tested in tests/unit/menu-bridge/tst_ongoing.cpp:
//  - Admission: a refusal remembered a few seconds, the cap on connections tracked (idle ones give their place), the rate
//    limit (End exempt);
//  - judgeCaller: each connection's identity, looked up once from the kernel (GetConnectionCredentials -> pidfd,
//    /proc/<pid>/root/.flatpak-info or /proc/<pid>/cgroup -> an installed desktop entry); its calls wait for it (at most
//    ongoing::kMaxQueued);
//  - Host: the activities, the lock state and the menu/1 "ongoing" / "ongoing-end" lines (redacted while the shell reports
//    the session locked, and until it reports anything); a connection that leaves the bus ends its activities; the shell's
//    click on a button comes back through invoke(), and ActionInvoked goes to the activity's owner only.

#include "Ongoing.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>
#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QTimer>

#include <functional>

class QDBusServiceWatcher;

namespace gf::menubridge::ongoing {

    class OngoingObject : public QDBusVirtualObject {
      public:
        using Send = Host::Send;

        explicit OngoingObject(Send send);
        ~OngoingObject() override;

        OngoingObject(const OngoingObject&)            = delete;
        OngoingObject& operator=(const OngoingObject&) = delete;

        // Attaches the sender watcher and the identity look-ups to `connection` (once, before the object is registered).
        void    setConnection(const QDBusConnection& connection);
        QString introspect(const QString& path) const override;
        bool    handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override;

        void              resetLock() {
            m_host.resetLock();
        }
        void              setLocked(bool locked) {
            m_host.setLocked(locked);
        }
        bool              locked() const {
            return m_host.locked();
        }
        QList<QByteArray> snapshot() const {
            return m_host.snapshot();
        }
        // The shell's click on button `action` of activity `key`: "" when ActionInvoked was sent, else Host's error code.
        QString           invoke(const QString& key, const QString& action);
        const Book&       book() const {
            return m_host.book();
        }

      private:
        struct Peer {
            enum class Stage { Resolving, Ready };
            Stage               stage = Stage::Resolving;
            QString             appId;
            QList<QDBusMessage> queued;
        };

        void   resolve(const QString& sender);
        void   resolved(const QString& sender, const Verdict& verdict);
        void   process(const QDBusMessage& message, const QString& appId);
        void   forgetPeer(const QString& sender);
        void   dropSender(const QString& sender);
        void   ensureIndex(bool missed);
        qint64 nowMs() const;
        void   reply(const QDBusMessage& message, const QVariantList& values = {});
        void   error(const QDBusMessage& message, const QString& name, const QString& text);

        Host                 m_host;
        Admission            m_admission;
        QDBusConnection      m_bus{QString()};
        QDBusServiceWatcher* m_watcher = nullptr;
        QHash<QString, Peer> m_peers;
        DesktopIndex         m_index;
        QElapsedTimer        m_indexAge; // invalid: never scanned
        QElapsedTimer        m_clock;    // monotonic: the rate limit and the refusals
        QTimer               m_sweep;    // ends activities past their end time
    };

} // namespace gf::menubridge::ongoing
