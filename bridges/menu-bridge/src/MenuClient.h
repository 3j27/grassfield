#pragma once

// DBusMenu client of one window (com.canonical.dbusmenu at a verified unique bus name and object path).
//
// Chromium exports no introspection data, so every call is built with explicit D-Bus types:
//   GetLayout(int32 0, int32 -1, as [])  ->  (uint32 revision, (ia{sv}av) layout)
//   AboutToShow(int32 id)                ->  bool needUpdate
//   Event(int32 id, "clicked", variant<int32 0>, uint32 timestamp)
// LayoutUpdated and ItemsPropertiesUpdated trigger a (coalesced) new GetLayout. The menu is dropped when the
// service leaves the bus (NameOwnerChanged). Only ids present in the latest layout are ever sent to the app.

#include "Layout.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QJsonArray>
#include <QObject>
#include <QString>
#include <QTimer>

namespace gf::menubridge {

    class MenuClient : public QObject {
        Q_OBJECT

      public:
        MenuClient(const QDBusConnection& bus, QString window, QString service, QString path, QObject* parent = nullptr);
        ~MenuClient() override;

        MenuClient(const MenuClient&)            = delete;
        MenuClient& operator=(const MenuClient&) = delete;

        // Subscribes to the menu's signals and fetches the layout.
        void start();

        // AboutToShow on a submenu of the latest layout (false: unknown id, nothing sent).
        bool aboutToShow(int id);
        // Event "clicked" on an enabled leaf of the latest layout (false: unknown or inactive id, nothing sent).
        bool activate(int id);

        const QString& window() const {
            return m_window;
        }
        const QString& service() const {
            return m_service;
        }
        const QString& path() const {
            return m_path;
        }
        // The latest mapped layout (empty before the first GetLayout reply).
        const QJsonArray& items() const {
            return m_items;
        }
        bool ready() const {
            return m_ready;
        }

      signals:
        void menuChanged(const QString& window);
        // code: "gone", "layout-failed" or "oversized". After it the client sends nothing more.
        void failed(const QString& window, const QString& code, const QString& message);

      private slots:
        void onMenuSignal(const QDBusMessage& message);

      private:
        void fetch();
        void scheduleRefetch();
        void fail(const QString& code, const QString& why);

        QDBusConnection     m_bus;
        QString             m_window;
        QString             m_service;
        QString             m_path;
        QDBusServiceWatcher m_watcher;
        QTimer              m_refetch;
        QJsonArray          m_items;
        ItemIndex           m_index;
        bool                m_ready    = false;
        bool                m_fetching = false;
        bool                m_again    = false;
        bool                m_gone     = false;
        bool                m_stopped  = false; // gave up (failure or oversized layout): no further GetLayout
        int                 m_failures = 0;     // consecutive failed re-reads
    };

} // namespace gf::menubridge
