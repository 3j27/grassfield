// Shared by the Grassfield apps and grassfield-ongoing (R5: one copy): publishes ongoing activities to the menu bar through
// org.grassfield.Ongoing1 (ADR-0052, bridges/menu-bridge/dbus/org.grassfield.Ongoing1.xml). The app says what it wants shown
// (set, end, or sync with the whole set); this client sends the changes, at most two a second per activity (a progress
// that moves faster is coalesced: the latest state wins), fits the text to the host's limits, and publishes everything
// again when the host's name comes back (the bridge restarted). A click on one of the activity's buttons arrives as
// actionInvoked(id, action), from the owner of org.grassfield.Ongoing1 only (QtDBus follows the name's owner).
// Without the host (another session, a dev run outside the nested shell) the calls fail quietly: one log line per error.
#pragma once

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <QtDebug>

#include <algorithm>
#include <utility>

namespace grassfield::apps {

// One button of an activity: a(ss) on the bus.
struct OngoingButton {
    QString id;    // [a-z][a-z0-9-]{0,31}
    QString label; // 1 to 24 characters (longer is elided)
    // Written out: the apps build as C++17 (no defaulted comparison).
    bool operator==(const OngoingButton &o) const { return id == o.id && label == o.label; }
    bool operator!=(const OngoingButton &o) const { return !(*this == o); }
};

inline QDBusArgument &operator<<(QDBusArgument &arg, const OngoingButton &b)
{
    arg.beginStructure();
    arg << b.id << b.label;
    arg.endStructure();
    return arg;
}

inline const QDBusArgument &operator>>(const QDBusArgument &arg, OngoingButton &b)
{
    arg.beginStructure();
    arg >> b.id >> b.label;
    arg.endStructure();
    return arg;
}

} // namespace grassfield::apps

Q_DECLARE_METATYPE(grassfield::apps::OngoingButton)

namespace grassfield::apps {

// What an app wants shown (ADR-0052 D1).
struct OngoingActivity {
    QString kind;     // timer, transfer, recording, install, call, progress
    QString title;    // 1 to 64 characters (longer is elided)
    QString subtitle; // up to 128 characters (longer is elided)
    double progress = -1; // 0..1; negative: indeterminate
    qint64 started = 0;   // Unix ms of the start (elapsed time), 0 for none
    qint64 ends = 0;      // Unix ms of the end (countdown), 0 for none
    QList<OngoingButton> actions; // at most 3
    bool operator==(const OngoingActivity &o) const
    {
        return kind == o.kind && title == o.title && subtitle == o.subtitle && progress == o.progress && started == o.started && ends == o.ends && actions == o.actions;
    }
    bool operator!=(const OngoingActivity &o) const { return !(*this == o); }
};

namespace ongoing {
inline constexpr char kService[] = "org.grassfield.Ongoing1";
inline constexpr char kPath[] = "/org/grassfield/Ongoing1";
inline constexpr char kInterface[] = "org.grassfield.Ongoing1";
inline constexpr int kMaxTitle = 64;
inline constexpr int kMaxSubtitle = 128;
inline constexpr int kMaxLabel = 24;
inline constexpr int kMaxActions = 3;
inline constexpr qint64 kMinIntervalMs = 500; // two updates a second per activity
inline constexpr int kMaxShown = 3;           // the host's limit per application (ADR-0052 D3): more would be refused
inline constexpr int kEndRetryMs = 1000;      // a failed End is sent once more after this long

// The activities shown, of those wanted: the first kMaxShown in the order the app first asked for them (a fourth copy job
// waits for one of the first three to end instead of being refused by the host at each update).
inline QStringList shown(const QStringList &order, const QSet<QString> &wanted)
{
    QStringList out;
    for (const QString &id : order) {
        if (out.size() >= kMaxShown)
            break;
        if (wanted.contains(id))
            out << id;
    }
    return out;
}

// `text` on one line within `max` characters: white space collapsed, an ellipsis at the end when it was longer.
inline QString fit(const QString &text, int max)
{
    QString s = text.simplified();
    if (s.size() <= max)
        return s;
    qsizetype cut = max - 1;
    if (cut > 0 && s.at(cut - 1).isHighSurrogate())
        --cut;
    return s.left(cut).trimmed() + QChar(0x2026);
}

// The Publish state of `a` (the a{sv} of org.grassfield.Ongoing1.Publish), fitted to the host's limits.
inline QVariantMap state(const OngoingActivity &a)
{
    QVariantMap m{{QStringLiteral("kind"), a.kind}, {QStringLiteral("title"), fit(a.title, kMaxTitle)}};
    const QString subtitle = fit(a.subtitle, kMaxSubtitle);
    if (!subtitle.isEmpty())
        m.insert(QStringLiteral("subtitle"), subtitle);
    if (a.progress >= 0)
        m.insert(QStringLiteral("progress"), qMin(a.progress, 1.0));
    if (a.started > 0)
        m.insert(QStringLiteral("started"), a.started);
    else if (a.ends > 0)
        m.insert(QStringLiteral("ends"), a.ends);
    if (!a.actions.isEmpty()) {
        QList<OngoingButton> buttons;
        for (const OngoingButton &b : a.actions.mid(0, kMaxActions))
            buttons.append({b.id, fit(b.label, kMaxLabel)});
        m.insert(QStringLiteral("actions"), QVariant::fromValue(buttons));
    }
    return m;
}
} // namespace ongoing

class OngoingPublisher : public QObject
{
    Q_OBJECT
public:
    explicit OngoingPublisher(QObject *parent = nullptr, const QDBusConnection &bus = QDBusConnection::sessionBus())
        : QObject(parent)
        , m_bus(bus)
        , m_watcher(QString::fromLatin1(ongoing::kService), bus, QDBusServiceWatcher::WatchForRegistration)
    {
        qDBusRegisterMetaType<OngoingButton>();
        qDBusRegisterMetaType<QList<OngoingButton>>();
        m_clock.start();
        m_timer.setSingleShot(true);
        connect(&m_timer, &QTimer::timeout, this, &OngoingPublisher::flush);
        // The bridge (re)started: it knows nothing of this app's activities.
        connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
            m_sent.clear();
            m_last.clear();
            flush();
        });
        if (m_bus.isConnected())
            m_bus.connect(QString::fromLatin1(ongoing::kService), QString::fromLatin1(ongoing::kPath), QString::fromLatin1(ongoing::kInterface),
                          QStringLiteral("ActionInvoked"), this, SLOT(onActionInvoked(QString, QString)));
    }

    ~OngoingPublisher() override
    {
        // Ended at once: the host would also end them when this connection leaves the bus.
        for (auto it = m_sent.cbegin(); it != m_sent.cend(); ++it)
            call(QStringLiteral("End"), {it.key()});
    }

    // Shows or updates activity `id` ([A-Za-z0-9_-]{1,64}, the app's own).
    void set(const QString &id, const OngoingActivity &activity)
    {
        if (m_wanted.value(id) == activity && m_wanted.contains(id))
            return;
        m_wanted.insert(id, activity);
        if (!m_order.contains(id))
            m_order << id;
        schedule();
    }

    void end(const QString &id)
    {
        if (m_wanted.remove(id) > 0) {
            m_order.removeAll(id);
            schedule();
        }
    }

    // The whole set: the ones not in `wanted` end.
    void sync(const QHash<QString, OngoingActivity> &wanted)
    {
        if (wanted == m_wanted)
            return;
        m_wanted = wanted;
        m_order.erase(std::remove_if(m_order.begin(), m_order.end(), [this](const QString &id) { return !m_wanted.contains(id); }), m_order.end());
        QStringList added;
        for (auto it = m_wanted.cbegin(); it != m_wanted.cend(); ++it) {
            if (!m_order.contains(it.key()))
                added << it.key();
        }
        std::sort(added.begin(), added.end()); // several new at once: a stable order
        m_order << added;
        schedule();
    }

signals:
    void actionInvoked(const QString &id, const QString &action);

private slots:
    void onActionInvoked(const QString &id, const QString &action)
    {
        if (m_wanted.contains(id))
            emit actionInvoked(id, action);
    }

private:
    void schedule()
    {
        if (!m_timer.isActive())
            m_timer.start(0);
    }

    // `retries`: how many more times a failed call is sent (End: once; an activity left behind would stay in the bar).
    void call(const QString &method, const QVariantList &args, int retries = 0)
    {
        if (!m_bus.isConnected())
            return;
        QDBusMessage msg = QDBusMessage::createMethodCall(QString::fromLatin1(ongoing::kService), QString::fromLatin1(ongoing::kPath),
                                                          QString::fromLatin1(ongoing::kInterface), method);
        msg.setArguments(args);
        auto *w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, 2000), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, method, args, retries](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusMessage reply = watcher->reply();
            if (reply.type() == QDBusMessage::ErrorMessage && retries > 0)
                QTimer::singleShot(ongoing::kEndRetryMs, this, [this, method, args, retries] { call(method, args, retries - 1); });
            if (reply.type() == QDBusMessage::ErrorMessage && !m_logged.contains(reply.errorName())) {
                m_logged.insert(reply.errorName());
                qInfo().noquote() << "grassfield: ongoing activity not shown:" << reply.errorName() << reply.errorMessage();
            }
        });
    }

    void flush()
    {
        const qint64 now = m_clock.elapsed();
        qint64 wait = -1;
        const QSet<QString> wantedIds(m_wanted.keyBegin(), m_wanted.keyEnd());
        const QStringList visible = ongoing::shown(m_order, wantedIds);
        for (const QString &id : visible) {
            const OngoingActivity &a = m_wanted[id];
            if (m_sent.contains(id) && m_sent.value(id) == a)
                continue;
            const qint64 last = m_last.value(id, -ongoing::kMinIntervalMs);
            if (now - last < ongoing::kMinIntervalMs) {
                const qint64 left = ongoing::kMinIntervalMs - (now - last);
                wait = wait < 0 ? left : qMin(wait, left);
                continue;
            }
            call(QStringLiteral("Publish"), {id, ongoing::state(a)});
            m_sent.insert(id, a);
            m_last.insert(id, now);
        }
        for (auto it = m_sent.begin(); it != m_sent.end();) {
            if (visible.contains(it.key())) {
                ++it;
                continue;
            }
            call(QStringLiteral("End"), {it.key()}, 1);
            m_last.remove(it.key());
            it = m_sent.erase(it);
        }
        if (wait >= 0)
            m_timer.start(int(wait));
    }

    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    QHash<QString, OngoingActivity> m_wanted;
    QStringList m_order; // ids in the order they were first wanted (ongoing::shown)
    QHash<QString, OngoingActivity> m_sent;
    QHash<QString, qint64> m_last;
    QSet<QString> m_logged;
    QElapsedTimer m_clock;
    QTimer m_timer;
};

} // namespace grassfield::apps
