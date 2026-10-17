#include "MenuClient.h"

#include "Log.h"

#include <QDBusArgument>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

#include <utility>

namespace gf::menubridge {

    namespace {
        const QString kInterface = QStringLiteral("com.canonical.dbusmenu");
        constexpr int kCallTimeoutMs = 3000;
        // Bursts of LayoutUpdated / ItemsPropertiesUpdated collapse into one GetLayout.
        constexpr int kRefetchDelayMs = 40;
        // Consecutive failed re-reads of a menu that was shown before the bridge gives up on it.
        constexpr int kMaxFailures = 3;
    } // namespace

    MenuClient::MenuClient(const QDBusConnection& bus, QString window, QString service, QString path, QObject* parent) :
        QObject(parent), m_bus(bus), m_window(std::move(window)), m_service(std::move(service)), m_path(std::move(path)) {
        m_refetch.setSingleShot(true);
        m_refetch.setInterval(kRefetchDelayMs);
        connect(&m_refetch, &QTimer::timeout, this, &MenuClient::fetch);

        m_watcher.setConnection(m_bus);
        m_watcher.setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        m_watcher.addWatchedService(m_service);
        connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString&) {
            if (m_gone)
                return;
            m_gone = true;
            m_refetch.stop();
            emit failed(m_window, QStringLiteral("gone"), QStringLiteral("the application left the bus"));
        });
    }

    MenuClient::~MenuClient() {
        m_bus.disconnect(m_service, m_path, kInterface, QStringLiteral("LayoutUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        m_bus.disconnect(m_service, m_path, kInterface, QStringLiteral("ItemsPropertiesUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
    }

    void MenuClient::start() {
        // A slot taking only a QDBusMessage accepts any signature: the signal arguments are not trusted or needed,
        // the layout is re-read instead.
        m_bus.connect(m_service, m_path, kInterface, QStringLiteral("LayoutUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        m_bus.connect(m_service, m_path, kInterface, QStringLiteral("ItemsPropertiesUpdated"), this, SLOT(onMenuSignal(QDBusMessage)));
        fetch();
    }

    void MenuClient::onMenuSignal(const QDBusMessage& /*message*/) {
        scheduleRefetch();
    }

    void MenuClient::scheduleRefetch() {
        // Not restarted while pending: a burst of signals less than kRefetchDelayMs apart would otherwise push the
        // refetch back for as long as it lasts. During a burst the layout is read at most every kRefetchDelayMs.
        if (!m_gone && !m_stopped && !m_refetch.isActive())
            m_refetch.start();
    }

    void MenuClient::fetch() {
        if (m_gone || m_stopped)
            return;
        if (m_fetching) {
            m_again = true;
            return;
        }
        m_fetching    = true;
        auto* watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(getLayoutCall(m_service, m_path), kCallTimeoutMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher* w) {
            w->deleteLater();
            m_fetching            = false;
            const QDBusMessage reply = w->reply();
            if (m_gone || m_stopped)
                return;
            if (reply.type() != QDBusMessage::ReplyMessage || reply.signature() != QLatin1String("u(ia{sv}av)") || reply.arguments().size() != 2) {
                const QString why = reply.type() == QDBusMessage::ErrorMessage ? reply.errorName() : QStringLiteral("unexpected reply signature %1").arg(reply.signature());
                log(QStringLiteral("window %1: GetLayout on %2 %3 failed: %4").arg(m_window, m_service, m_path, why));
                fail(QStringLiteral("layout-failed"), why);
                return;
            }
            RawItem      root;
            LayoutBudget readBudget;
            if (!readLayout(qvariant_cast<QDBusArgument>(reply.arguments().at(1)), root, 0, readBudget)) {
                fail(QStringLiteral("layout-failed"), QStringLiteral("malformed layout"));
                return;
            }
            if (readBudget.truncated) {
                // More items or levels than any real menu has: the application is not trusted any more, its menu is not
                // shown and no further GetLayout is sent (the bridge remembers the refusal, see Bridge::refuse).
                log(QStringLiteral("window %1: menu of %2 has more than %3 items or %4 levels: refused").arg(m_window, m_service).arg(limits::kItems).arg(limits::kDepth));
                m_stopped = true;
                m_refetch.stop();
                emit failed(m_window, QStringLiteral("oversized"), QStringLiteral("the menu is larger than the supported limits"));
                return;
            }
            m_failures = 0;
            LayoutBudget mapBudget;
            m_items = mapChildren(root, mapBudget);
            m_index = indexItems(m_items);
            m_ready = true;
            emit menuChanged(m_window);
            if (std::exchange(m_again, false))
                fetch();
        });
    }

    void MenuClient::fail(const QString& code, const QString& why) {
        // The first layout never arrived: the menu cannot be shown. Later failures keep the previous menu until the
        // application keeps failing.
        if (!m_ready || ++m_failures >= kMaxFailures) {
            m_stopped = true;
            m_refetch.stop();
            emit failed(m_window, code, why);
        }
    }

    bool MenuClient::aboutToShow(int id) {
        if (m_gone || !m_index.submenus.contains(id))
            return false;
        auto* watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(aboutToShowCall(m_service, m_path, id), kCallTimeoutMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher* w) {
            w->deleteLater();
            const QDBusMessage reply = w->reply();
            // needUpdate = true: the application changed the submenu; read it again.
            if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 1 && reply.arguments().at(0).toBool())
                scheduleRefetch();
        });
        return true;
    }

    bool MenuClient::activate(int id) {
        if (m_gone || !m_index.activatable.contains(id))
            return false;
        auto* watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(eventCall(m_service, m_path, id), kCallTimeoutMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher* w) {
            w->deleteLater();
            const QDBusMessage reply = w->reply();
            if (reply.type() == QDBusMessage::ErrorMessage)
                log(QStringLiteral("window %1: Event(%2, clicked) failed: %3").arg(m_window).arg(id).arg(reply.errorName()));
        });
        return true;
    }

} // namespace gf::menubridge
