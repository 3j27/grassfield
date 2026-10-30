// The Energy tab's battery (spec AM39): UPower on the system bus, read only. The display device gives the charge, the state
// and the times; the laptop battery's charge history gives the Battery (Last 12 hours) graph and the time on battery or
// on AC (the last change of power source it shows). Asked while the Energy tab is shown: the device at each sample, the
// history at most once a minute.
#pragma once

#include <QDBusArgument>
#include <QDateTime>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

namespace activity {

// UPower's Device.State.
enum class BatteryCharge { Unknown = 0, Charging = 1, Discharging = 2, Empty = 3, Full = 4, PendingCharge = 5, PendingDischarge = 6 };

// One entry of GetHistory("charge", ...): seconds since the epoch, percent, state.
struct ChargeEntry {
    uint time = 0;
    double percent = 0;
    uint state = 0;
};

struct BatteryState {
    bool present = false;       // a battery powers this computer (the display device is present and is a battery)
    double percent = -1;        // Percentage
    BatteryCharge charge = BatteryCharge::Unknown;
    qint64 timeToEmpty = 0;     // seconds, 0 while UPower estimates it
    qint64 timeToFull = 0;
    qint64 sourceSince = 0;     // seconds since the epoch of the last change between battery and AC, 0 when unknown
    QList<ChargeEntry> history; // the last 12 hours, oldest first
    bool operator==(const BatteryState &o) const;
};

// The display device's properties (org.freedesktop.UPower.Device) into a state; history and sourceSince are left as they are.
void applyDeviceProperties(const QVariantMap &props, BatteryState &state);
// On battery: discharging, empty or pending discharge.
bool onBattery(BatteryCharge charge);
// The time the power source last changed, from the history (oldest first) and whether the computer is on battery now: the
// first entry of the run of entries that agree with now and end the history; 0 when the whole history agrees (the change is
// older than it) or it is empty.
qint64 lastSourceChange(const QList<ChargeEntry> &history, bool onBatteryNow);
// The laptop battery among UPower's device paths: the first whose name starts with "battery_" (UPower names peripherals by
// their kind: mouse_, keyboard_...), "" when none does.
QString batteryPath(const QStringList &paths);

class BatteryWatch : public QObject
{
    Q_OBJECT

public:
    explicit BatteryWatch(QObject *parent = nullptr);
    // One asynchronous read of the display device, and of the history when it is a minute old; at most one in flight.
    void refresh();
    const BatteryState &state() const { return m_state; }

signals:
    void changed();

private:
    void readHistory();
    void finish(const BatteryState &next);

    BatteryState m_state;
    QString m_battery; // the battery's object path, found once
    bool m_pending = false;
    QDateTime m_historyAt;
};

} // namespace activity

QDBusArgument &operator<<(QDBusArgument &arg, const activity::ChargeEntry &e);
const QDBusArgument &operator>>(const QDBusArgument &arg, activity::ChargeEntry &e);
Q_DECLARE_METATYPE(activity::ChargeEntry)
