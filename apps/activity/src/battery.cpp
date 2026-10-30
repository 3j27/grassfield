#include "battery.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

#include <algorithm>

QDBusArgument &operator<<(QDBusArgument &arg, const activity::ChargeEntry &e)
{
    arg.beginStructure();
    arg << e.time << e.percent << e.state;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, activity::ChargeEntry &e)
{
    arg.beginStructure();
    arg >> e.time >> e.percent >> e.state;
    arg.endStructure();
    return arg;
}

namespace activity {

namespace {

const QString kService = QStringLiteral("org.freedesktop.UPower");
const QString kDevice = QStringLiteral("org.freedesktop.UPower.Device");
const QString kDisplay = QStringLiteral("/org/freedesktop/UPower/devices/DisplayDevice");
constexpr uint kTypeBattery = 2;
constexpr int kCallMs = 2000;
constexpr qint64 kHistoryEverySecs = 60;

} // namespace

bool BatteryState::operator==(const BatteryState &o) const
{
    if (present != o.present || percent != o.percent || charge != o.charge || timeToEmpty != o.timeToEmpty
        || timeToFull != o.timeToFull || sourceSince != o.sourceSince || history.size() != o.history.size())
        return false;
    for (qsizetype i = 0; i < history.size(); ++i) {
        if (history[i].time != o.history[i].time || history[i].percent != o.history[i].percent || history[i].state != o.history[i].state)
            return false;
    }
    return true;
}

void applyDeviceProperties(const QVariantMap &props, BatteryState &state)
{
    state.present = props.value(QStringLiteral("IsPresent")).toBool() && props.value(QStringLiteral("Type")).toUInt() == kTypeBattery;
    if (!state.present) {
        state.percent = -1;
        state.charge = BatteryCharge::Unknown;
        state.timeToEmpty = state.timeToFull = 0;
        return;
    }
    state.percent = qBound(0.0, props.value(QStringLiteral("Percentage")).toDouble(), 100.0);
    const uint charge = props.value(QStringLiteral("State")).toUInt();
    state.charge = charge <= 6 ? static_cast<BatteryCharge>(charge) : BatteryCharge::Unknown;
    state.timeToEmpty = qMax<qint64>(0, props.value(QStringLiteral("TimeToEmpty")).toLongLong());
    state.timeToFull = qMax<qint64>(0, props.value(QStringLiteral("TimeToFull")).toLongLong());
}

bool onBattery(BatteryCharge charge)
{
    return charge == BatteryCharge::Discharging || charge == BatteryCharge::Empty || charge == BatteryCharge::PendingDischarge;
}

qint64 lastSourceChange(const QList<ChargeEntry> &history, bool onBatteryNow)
{
    // An entry whose state UPower did not know says nothing about the source.
    qsizetype i = history.size() - 1;
    qint64 since = 0;
    for (; i >= 0; --i) {
        const BatteryCharge c = history[i].state <= 6 ? static_cast<BatteryCharge>(history[i].state) : BatteryCharge::Unknown;
        if (c == BatteryCharge::Unknown)
            continue;
        if (onBattery(c) != onBatteryNow)
            return since;
        since = history[i].time;
    }
    return 0; // the whole history agrees with now: the change is older than it
}

QString batteryPath(const QStringList &paths)
{
    for (const QString &p : paths) {
        if (p.section(QLatin1Char('/'), -1).startsWith(QLatin1String("battery_")))
            return p;
    }
    return QString();
}

BatteryWatch::BatteryWatch(QObject *parent)
    : QObject(parent)
{
    qDBusRegisterMetaType<ChargeEntry>();
    qDBusRegisterMetaType<QList<ChargeEntry>>();
}

void BatteryWatch::refresh()
{
    if (m_pending)
        return;
    QDBusConnection bus = QDBusConnection::systemBus();
    if (!bus.isConnected())
        return; // no system bus (a container): no battery shows
    QDBusMessage call = QDBusMessage::createMethodCall(kService, kDisplay, QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("GetAll"));
    call << kDevice;
    m_pending = true;
    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, kCallMs), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QVariantMap> reply = *w;
        w->deleteLater();
        BatteryState next = m_state;
        applyDeviceProperties(reply.isValid() ? reply.value() : QVariantMap(), next);
        if (!next.present) {
            next.history.clear();
            next.sourceSince = 0;
            finish(next);
            return;
        }
        const bool sourceChanged = onBattery(next.charge) != onBattery(m_state.charge);
        finish(next);
        const QDateTime now = QDateTime::currentDateTimeUtc();
        if (sourceChanged || !m_historyAt.isValid() || m_historyAt.secsTo(now) >= kHistoryEverySecs) {
            m_pending = true;
            readHistory();
        }
    });
}

void BatteryWatch::readHistory()
{
    QDBusConnection bus = QDBusConnection::systemBus();
    m_historyAt = QDateTime::currentDateTimeUtc();
    if (m_battery.isEmpty()) {
        const QDBusMessage call = QDBusMessage::createMethodCall(kService, QStringLiteral("/org/freedesktop/UPower"), kService,
                                                                 QStringLiteral("EnumerateDevices"));
        auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, kCallMs), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
            const QDBusPendingReply<QList<QDBusObjectPath>> reply = *w;
            w->deleteLater();
            QStringList paths;
            if (reply.isValid()) {
                for (const QDBusObjectPath &p : reply.value())
                    paths << p.path();
            }
            m_battery = batteryPath(paths);
            if (m_battery.isEmpty()) {
                m_pending = false; // no history to read: the graph stays empty
                return;
            }
            readHistory();
        });
        return;
    }
    QDBusMessage call = QDBusMessage::createMethodCall(kService, m_battery, kDevice, QStringLiteral("GetHistory"));
    call << QStringLiteral("charge") << uint(12 * 3600) << uint(120); // Battery (Last 12 hours), AM39
    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, kCallMs), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QList<ChargeEntry>> reply = *w;
        w->deleteLater();
        BatteryState next = m_state;
        next.history = reply.isValid() ? reply.value() : QList<ChargeEntry>();
        // UPower gives the newest first; the graph reads them oldest first.
        std::sort(next.history.begin(), next.history.end(), [](const ChargeEntry &a, const ChargeEntry &b) { return a.time < b.time; });
        next.sourceSince = lastSourceChange(next.history, onBattery(next.charge));
        finish(next);
    });
}

void BatteryWatch::finish(const BatteryState &next)
{
    m_pending = false;
    if (next == m_state)
        return;
    m_state = next;
    emit changed();
}

} // namespace activity
