#include "MenuClient.h"

#include "Log.h"
#include "Memory.h"

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
        // Consecutive failed reads before the bridge gives up on a menu, the first read included. A failed read is tried
        // again after kRetryDelayMs, doubled each time (0.5, 1, 2 s), and a menu shown before stays shown meanwhile: an
        // application busy for longer than a call's timeout (Files drawing the Applications location on a loaded machine:
        // GetLayout NoReply) or whose menu object is not exported yet gets its menu once it answers, about 15 s at most.
        constexpr int kMaxFailures  = 4;
        constexpr int kRetryDelayMs = 500;
    } // namespace

    MenuClient::MenuClient(const QDBusConnection& bus, QString window, QString service, QString path, QObject* parent) :
        QObject(parent), m_bus(bus), m_window(std::move(window)), m_service(std::move(service)), m_path(std::move(path)) {
        m_refetch.setSingleShot(true);
        m_refetch.setInterval(kRefetchDelayMs);
        connect(&m_refetch, &QTimer::timeout, this, &MenuClient::fetch);
        m_retry.setSingleShot(true);
        connect(&m_retry, &QTimer::timeout, this, &MenuClient::fetch);

        m_watcher.setConnection(m_bus);
        m_watcher.setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
        m_watcher.addWatchedService(m_service);
        connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString&) {
            if (m_gone)
                return;
            m_gone = true;
            m_refetch.stop();
            m_retry.stop();
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
        m_fetching = true;
        track(getLayoutCall(m_service, m_path), [this](const QDBusMessage& reply) {
            m_fetching = false;
            if (m_gone || m_stopped)
                return;
            handleLayout(reply);
        });
    }

    void MenuClient::handleLayout(const QDBusMessage& reply) {
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
            // shown and no further GetLayout is sent (the bridge remembers the refusal, see PenaltyBook).
            log(QStringLiteral("window %1: menu of %2 has more than %3 items or %4 levels: refused").arg(m_window, m_service).arg(limits::kItems).arg(limits::kDepth));
            m_stopped = true;
            m_refetch.stop();
            m_retry.stop();
            emit failed(m_window, QStringLiteral("oversized"), QStringLiteral("the menu is larger than the supported limits"));
            return;
        }
        m_failures = 0;
        m_retry.stop();
        LayoutBudget mapBudget;
        m_items = mapChildren(root, mapBudget);
        m_index = indexItems(m_items);
        m_ready = true;
        emit menuChanged(m_window);
        if (std::exchange(m_again, false))
            fetch();
    }

    void MenuClient::fail(const QString& code, const QString& why) {
        // Read again later (a menu shown before stays shown), until the application keeps failing. The first read used
        // to fail at once: a window whose application was busy past the timeout showed the T0 menus until its next focus.
        if (++m_failures >= kMaxFailures) {
            m_stopped = true;
            m_refetch.stop();
            m_retry.stop();
            emit failed(m_window, code, why);
            return;
        }
        log(QStringLiteral("window %1: reading its menu again in %2 ms (%3 of %4)").arg(m_window).arg(kRetryDelayMs << (m_failures - 1)).arg(m_failures).arg(kMaxFailures));
        m_retry.start(kRetryDelayMs << (m_failures - 1));
    }

    void MenuClient::track(const QDBusMessage& message, std::function<void(const QDBusMessage&)> handler) {
        ++m_outstanding;
        emit callBegun();
        auto* watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message, kCallTimeoutMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, handler = std::move(handler)](QDBusPendingCallWatcher* w) {
            {
                const QDBusMessage reply = w->reply();
                w->deleteLater();
                handler(reply);
            }
            --m_outstanding;
            emit callEnded();
            trimMemorySoon(); // the reply (possibly tens of MB) is released with the watcher
        });
    }

    bool MenuClient::aboutToShow(int id) {
        if (m_gone || !m_index.submenus.contains(id))
            return false;
        track(aboutToShowCall(m_service, m_path, id), [this](const QDBusMessage& reply) {
            // needUpdate = true: the application changed the submenu; read it again.
            if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 1 && reply.arguments().at(0).toBool())
                scheduleRefetch();
        });
        return true;
    }

    bool MenuClient::activate(int id) {
        if (m_gone || !m_index.activatable.contains(id))
            return false;
        track(eventCall(m_service, m_path, id), [this, id](const QDBusMessage& reply) {
            if (reply.type() == QDBusMessage::ErrorMessage)
                log(QStringLiteral("window %1: Event(%2, clicked) failed: %3").arg(m_window).arg(id).arg(reply.errorName()));
        });
        return true;
    }

} // namespace gf::menubridge
