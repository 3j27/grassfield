#include "efficiency.h"

#include "runmode.h"
#include "signals.h"
#include "units.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QDebug>
#include <QList>

namespace {

// SetUnitProperties' a(sv).
struct UnitProperty {
    QString name;
    QDBusVariant value;
};

QDBusArgument &operator<<(QDBusArgument &arg, const UnitProperty &p)
{
    arg.beginStructure();
    arg << p.name << p.value;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, UnitProperty &p)
{
    arg.beginStructure();
    arg >> p.name >> p.value;
    arg.endStructure();
    return arg;
}

const QString kSystemd = QStringLiteral("org.freedesktop.systemd1");

} // namespace

Q_DECLARE_METATYPE(UnitProperty)

namespace activity
{

Efficiency::Efficiency(std::string procRoot, QObject *parent)
    : QObject(parent)
    , m_procRoot(std::move(procRoot))
{
    m_call = [this](const QString &unit, quint64 weight, std::function<void(const QString &)> answer) {
        static const bool registered = [] {
            qDBusRegisterMetaType<UnitProperty>();
            qDBusRegisterMetaType<QList<UnitProperty>>();
            return true;
        }();
        Q_UNUSED(registered);
        QDBusMessage call = QDBusMessage::createMethodCall(kSystemd, QStringLiteral("/org/freedesktop/systemd1"),
                                                          QStringLiteral("org.freedesktop.systemd1.Manager"),
                                                          QStringLiteral("SetUnitProperties"));
        // Runtime only (AM68): nothing outlives the unit, which ends with the launch.
        call << unit << true << QVariant::fromValue(QList<UnitProperty>{{QStringLiteral("CPUWeight"), QDBusVariant(QVariant::fromValue(weight))}});
        auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call, 5000), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [watcher, answer](QDBusPendingCallWatcher *) {
            const QDBusPendingReply<> reply = *watcher;
            answer(reply.isError() ? (reply.error().name().isEmpty() ? QStringLiteral("error") : reply.error().name()) : QString());
            watcher->deleteLater();
        });
    };
}

bool Efficiency::userManagerPresent()
{
    QDBusConnectionInterface *bus = QDBusConnection::sessionBus().interface();
    return bus && bus->isServiceRegistered(kSystemd).value();
}

bool Efficiency::available() const
{
    return m_supported && m_target && m_target->own && m_target->eligible && !m_target->session;
}

QString Efficiency::reason() const
{
    if (!m_target || available() || !m_supported)
        return QString();
    if (m_target->own && m_target->session)
        return tr("This process is part of your session.");
    return tr("This process isn't running as an app.");
}

void Efficiency::setTarget(std::optional<Target> target)
{
    if (target == m_target)
        return;
    m_target = std::move(target);
    emit changed();
}

void Efficiency::setSupported(bool supported)
{
    if (supported == m_supported)
        return;
    m_supported = supported;
    emit changed();
}

void Efficiency::set(bool on)
{
    if (!available() || m_busy)
        return;
    const Target target = *m_target;
    // The unit now, through the process's descriptor (AD25: a row keeps no cgroup path); a process that ended or whose pid
    // is another's now changes nothing.
    std::string cgroup;
    int ppid = 0;
    if (m_unitReader) {
        cgroup = m_unitReader(target.pid);
    } else {
        const ProcessHandle handle = ProcessHandle::open(m_procRoot, target.pid, target.start);
        if (handle.valid()) {
            cgroup = handle.cgroup();
            ppid = handle.currentPpid();
        }
    }
    if (cgroup.empty()) {
        emit finished(tr("The process has ended."));
        return;
    }
    if (!efficiencyEligible(cgroup) || isSessionProcess(cgroup)) {
        emit finished(tr("This process isn't running as an app."));
        return;
    }
    // AM56: in a development session, only a process the nested session started.
    if (grassfield::apps::runmode::dev()) {
        const std::vector<DevRoot> roots = readDevRoots(grassfield::apps::runmode::devValue("ACTIVITY_DEV_ROOTS").toStdString());
        if (!underDevRoot(m_procRoot, target.pid, target.start, ppid, roots)) {
            qInfo().noquote() << "dev guard: Efficiency Mode of pid" << target.pid
                              << "refused: it descends from no process GRASSFIELD_ACTIVITY_DEV_ROOTS names";
            emit finished(tr("Development session: only the nested session's processes can be changed."));
            return;
        }
    }
    callWith(QString::fromStdString(std::string(unitOf(cgroup))), on ? kCpuWeightIdle : kCpuWeightUnset, on);
}

void Efficiency::callWith(const QString &unit, quint64 weight, bool on)
{
    m_busy = true;
    emit changed();
    m_call(unit, weight, [this, unit, weight, on](const QString &error) {
        // A systemd older than 252 has no idle weight: the lowest number then (AM68).
        if (on && weight == kCpuWeightIdle && error == QLatin1String("org.freedesktop.DBus.Error.InvalidArgs")) {
            callWith(unit, kCpuWeightMin, on);
            return;
        }
        m_busy = false;
        emit changed();
        if (!error.isEmpty())
            qInfo().noquote() << "Efficiency Mode of" << unit << "failed:" << error;
        emit finished(error.isEmpty() ? QString() : on ? tr("Efficiency Mode couldn't be turned on.") : tr("Efficiency Mode couldn't be turned off."));
    });
}

} // namespace activity
