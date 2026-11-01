// Efficiency Mode (ADR-0038 g; spec AM68, AM76): the selected process's app unit at the lowest CPU weight systemd accepts,
// through the user manager on the session bus (`SetUnitProperties(unit, runtime, [CPUWeight])`, the user's own units: no
// polkit). Available for one of the user's own processes in a unit uwsm named for one launch under app-graphical.slice,
// never a session process; the unit is read again through the process's /proc descriptor when the item is chosen (a row
// keeps none, AD25). Whether a unit runs in Efficiency Mode is the sampler's (ReadEfficiency: its cgroup), so a change made
// elsewhere shows too.
#pragma once

#include <QObject>
#include <QString>

#include <functional>
#include <optional>
#include <string>

namespace activity
{

// systemd's CPUWeight values on the bus (src/basic/cgroup-util.h): idle, the lowest weight, and none set.
constexpr quint64 kCpuWeightIdle = 0;
constexpr quint64 kCpuWeightMin = 1;
constexpr quint64 kCpuWeightUnset = ~quint64(0);

class Efficiency : public QObject
{
    Q_OBJECT
    // AM76: a systemd user manager answers on the session bus; without it every item is absent.
    Q_PROPERTY(bool supported READ supported NOTIFY changed)
    // The selected process: one of the user's own, in an app unit, not a session process.
    Q_PROPERTY(bool available READ available NOTIFY changed)
    // Its unit runs in Efficiency Mode (the item's check mark).
    Q_PROPERTY(bool on READ on NOTIFY changed)
    // Why the item is disabled (its tooltip); "" with no process or several selected.
    Q_PROPERTY(QString reason READ reason NOTIFY changed)
    // The app's name for the first time's sheet: the row's app, else its name.
    Q_PROPERTY(QString appName READ appName NOTIFY changed)
    // A change is on its way: the item waits for its answer.
    Q_PROPERTY(bool busy READ busy NOTIFY changed)

public:
    // The selected row as the last sample gave it.
    struct Target {
        int pid = 0;
        quint64 start = 0;
        QString appName;
        bool own = false;
        bool eligible = false; // the sampler's efficiencyEligible
        bool session = false;
        bool efficient = false;
        bool operator==(const Target &o) const
        {
            return pid == o.pid && start == o.start && appName == o.appName && own == o.own && eligible == o.eligible
                && session == o.session && efficient == o.efficient;
        }
    };

    explicit Efficiency(std::string procRoot, QObject *parent = nullptr);

    bool supported() const { return m_supported; }
    bool available() const;
    bool on() const { return m_target && m_target->efficient; }
    QString reason() const;
    QString appName() const { return m_target ? m_target->appName : QString(); }
    bool busy() const { return m_busy; }

    // One selected row, or none (none or several selected).
    void setTarget(std::optional<Target> target);
    // AM76: whether the user manager answers (asked once at start by default).
    void setSupported(bool supported);
    static bool userManagerPresent();

    // Turns Efficiency Mode on or off for the selected process's unit; `finished` gives the outcome ("" or the message).
    Q_INVOKABLE void set(bool on);

    // The bus call: `unit`, the weight, then the answer's error name ("" when it succeeded). By default
    // org.freedesktop.systemd1.Manager.SetUnitProperties on the session bus, runtime only; tests put their own.
    using Call = std::function<void(const QString &unit, quint64 weight, std::function<void(const QString &error)> answer)>;
    void setCall(Call call) { m_call = std::move(call); }
    // Tests: the cgroup path of the process, by its pid (by default read through its /proc descriptor).
    using UnitReader = std::function<std::string(int pid)>;
    void setUnitReader(UnitReader reader) { m_unitReader = std::move(reader); }

signals:
    void changed();
    // "" when the unit took the weight (a sample now shows it), else the message for the window.
    void finished(const QString &error);

private:
    void callWith(const QString &unit, quint64 weight, bool on);

    std::string m_procRoot;
    bool m_supported = false;
    bool m_busy = false;
    std::optional<Target> m_target;
    Call m_call;
    UnitReader m_unitReader;
};

} // namespace activity
