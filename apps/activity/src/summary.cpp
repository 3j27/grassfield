#include "summary.h"

#include "format.h"

#include <algorithm>
#include <cmath>

namespace activity {

namespace {

const QString kStacked = QStringLiteral("stacked"), kMirrored = QStringLiteral("mirrored"), kBars = QStringLiteral("bars"),
              kArea = QStringLiteral("area");

QVariantMap series(const History &history, const QString &color)
{
    return QVariantMap{{QStringLiteral("values"), history.toList()}, {QStringLiteral("color"), color}};
}

QVariantMap mode(const QString &key, const QString &title)
{
    return QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("title"), title}};
}

// A scale for a graph whose values have no fixed top: the largest kept, with room above it (never 0).
double scaleFor(double peak)
{
    return peak > 0 ? peak * 1.1 : 1.0;
}

} // namespace

void History::setCapacity(size_t capacity)
{
    m_capacity = std::max<size_t>(1, capacity);
    while (m_values.size() > m_capacity)
        m_values.pop_front();
}

void History::add(double value)
{
    m_values.push_back(std::isfinite(value) ? value : -1);
    while (m_values.size() > m_capacity)
        m_values.pop_front();
}

double History::peak() const
{
    double top = 0;
    for (double v : m_values)
        top = std::max(top, v);
    return top;
}

QVariantList History::toList() const
{
    QVariantList list;
    list.reserve(static_cast<qsizetype>(m_values.size()));
    for (double v : m_values)
        list << v;
    return list;
}

Summary::Summary(QObject *parent)
    : QObject(parent)
{
}

void Summary::setCapacity(int capacity)
{
    const size_t c = static_cast<size_t>(std::max(1, capacity));
    if (c == m_capacity)
        return;
    m_capacity = c;
    for (History *h : {&m_cpuSystem, &m_cpuUser, &m_memInUse, &m_memLevel, &m_energy, &m_diskReads, &m_diskWrites, &m_diskReadBytes,
                       &m_diskWriteBytes, &m_netPacketsIn, &m_netPacketsOut, &m_netBytesIn, &m_netBytesOut})
        h->setCapacity(c);
    emit capacityChanged();
    rebuild();
}

void Summary::setTab(Tab tab)
{
    if (tab == m_tab)
        return;
    m_tab = tab;
    rebuild();
}

void Summary::setLocale(const QLocale &locale)
{
    m_locale = locale;
    rebuild();
}

void Summary::setDiskMode(const QString &mode)
{
    const QString m = mode == QLatin1String("data") ? mode : QStringLiteral("io");
    if (m == m_diskMode)
        return;
    m_diskMode = m;
    rebuild();
}

void Summary::setNetworkMode(const QString &mode)
{
    const QString m = mode == QLatin1String("data") ? mode : QStringLiteral("packets");
    if (m == m_networkMode)
        return;
    m_networkMode = m;
    rebuild();
}

void Summary::addSample(const Snapshot &snapshot, const QDateTime &now)
{
    const SystemSnapshot &s = snapshot.system;
    m_system = s;
    m_now = now;
    m_haveSample = true;
    // AM29: the shares of the whole machine; a sample without its rates is a gap.
    const bool cpu = s.cpuOk && s.userShare >= 0 && s.systemShare >= 0;
    m_cpuSystem.add(cpu ? s.systemShare : -1);
    m_cpuUser.add(cpu ? s.userShare : -1);
    // AM33: the height is the memory in use, the colour the pressure level.
    m_memInUse.add(s.memory.ok ? s.memory.inUse : -1);
    m_memLevel.add(s.memory.ok ? static_cast<double>(s.memory.level) : -1);
    // AM39: the sum over the user's processes, only from the samples that computed it.
    if (snapshot.energyImpact >= 0)
        m_energy.add(snapshot.energyImpact);
    // AM42, AM44: every whole physical disk, every interface but lo.
    m_diskReads.add(s.diskTotal.readsPerSec);
    m_diskWrites.add(s.diskTotal.writesPerSec);
    m_diskReadBytes.add(s.diskTotal.readBytesPerSec);
    m_diskWriteBytes.add(s.diskTotal.writeBytesPerSec);
    m_netPacketsIn.add(s.netTotal.packetsInPerSec);
    m_netPacketsOut.add(s.netTotal.packetsOutPerSec);
    m_netBytesIn.add(s.netTotal.bytesInPerSec);
    m_netBytesOut.add(s.netTotal.bytesOutPerSec);
    rebuild();
}

void Summary::setBattery(const BatteryState &battery, const QDateTime &now)
{
    m_battery = battery;
    m_now = now;
    rebuild();
}

QString Summary::durationText(qint64 seconds)
{
    if (seconds < 0)
        return dash();
    const qint64 minutes = seconds / 60;
    return QStringLiteral("%1:%2").arg(minutes / 60).arg(minutes % 60, 2, 10, QLatin1Char('0'));
}

QVariantMap Summary::figure(const QString &label, const QString &value, const QString &swatch) const
{
    return QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("value"), value}, {QStringLiteral("swatch"), swatch}};
}

QVariantMap Summary::figures(const QVariantList &rows) const
{
    return QVariantMap{{QStringLiteral("kind"), QStringLiteral("figures")}, {QStringLiteral("rows"), rows}};
}

QVariantMap Summary::graph(const QString &key, const QString &title, const QString &style, double max, const QVariantList &series) const
{
    return QVariantMap{{QStringLiteral("kind"), QStringLiteral("graph")},
                       {QStringLiteral("key"), key},
                       {QStringLiteral("title"), title},
                       {QStringLiteral("style"), style},
                       {QStringLiteral("max"), max},
                       {QStringLiteral("series"), series}};
}

QString Summary::percent(double fraction) const
{
    if (fraction < 0)
        return dash();
    return tr("%1%").arg(formatDecimal(fraction * 100.0, m_locale));
}

void Summary::rebuild()
{
    QVariantList blocks;
    const SystemSnapshot &s = m_system;
    const bool known = m_haveSample;
    switch (m_tab) {
    case Tab::Cpu: {
        const bool cpu = known && s.cpuOk;
        blocks << figures({figure(tr("System:"), percent(cpu ? s.systemShare : -1), QStringLiteral("activityGraphSystem")),
                           figure(tr("User:"), percent(cpu ? s.userShare : -1), QStringLiteral("activityGraphUser")),
                           figure(tr("Idle:"), percent(cpu ? s.idleShare : -1))});
        blocks << graph(QStringLiteral("cpu"), tr("CPU Load"), kStacked, 1.0,
                        {series(m_cpuSystem, QStringLiteral("activityGraphSystem")), series(m_cpuUser, QStringLiteral("activityGraphUser"))});
        blocks << figures({figure(tr("Threads:"), formatCount(known ? s.tasks : -1, m_locale)),
                           figure(tr("Processes:"), formatCount(known ? s.processes : -1, m_locale))});
        break;
    }
    case Tab::Memory: {
        const MemorySummary &m = s.memory;
        const bool ok = known && m.ok;
        auto bytes = [&](uint64_t v) { return formatBytes(ok ? static_cast<double>(v) : -1, m_locale); };
        QVariantMap pressure = graph(QStringLiteral("pressure"), tr("Memory Pressure"), kBars, 1.0,
                                     {series(m_memInUse, QString())});
        pressure.insert(QStringLiteral("levels"), m_memLevel.toList());
        pressure.insert(QStringLiteral("levelColors"), QStringList{QStringLiteral("activityPressureGreen"), QStringLiteral("activityPressureYellow"),
                                                                   QStringLiteral("activityPressureRed")});
        blocks << pressure;
        blocks << figures({figure(tr("Physical Memory:"), bytes(m.physical)), figure(tr("Memory Used:"), bytes(m.used)),
                           figure(tr("Cached Files:"), bytes(m.cached)), figure(tr("Swap Used:"), bytes(m.swapUsed))});
        // AM34: "Compressed" is zram's; with a swap device that is not zram it still names zram's part, which is 0 without one.
        blocks << figures({figure(tr("App Memory:"), bytes(m.app)), figure(tr("Wired Memory:"), bytes(m.wired)),
                           figure(tr("Compressed:"), bytes(m.compressed))});
        break;
    }
    case Tab::Energy: {
        blocks << graph(QStringLiteral("energy"), tr("Energy Impact"), kArea, scaleFor(m_energy.peak()),
                        {series(m_energy, QStringLiteral("activityGraphUser"))});
        const BatteryState &b = m_battery;
        if (!b.present)
            break; // AM39: without a battery only the graph shows
        QVariantList rows;
        rows << figure(tr("Remaining charge:"), tr("%1%").arg(m_locale.toString(qRound(b.percent))));
        if (b.charge == BatteryCharge::Full) {
            rows << figure(tr("Battery Is Charged"), QString());
        } else if (b.charge == BatteryCharge::Charging || b.charge == BatteryCharge::PendingCharge) {
            rows << figure(tr("Time until full:"), b.timeToFull > 0 ? durationText(b.timeToFull) : tr("Calculating…"));
        } else {
            rows << figure(tr("Time remaining:"), b.timeToEmpty > 0 ? durationText(b.timeToEmpty) : tr("Calculating…"));
        }
        const qint64 since = b.sourceSince > 0 && m_now.isValid() ? m_now.toSecsSinceEpoch() - b.sourceSince : -1;
        rows << figure(onBattery(b.charge) ? tr("Time on battery:") : tr("Time on AC:"), durationText(since));
        blocks << figures(rows);
        // AM39: Battery (Last 12 hours), each value at its time.
        QVariantList values, xs;
        const qint64 end = m_now.isValid() ? m_now.toSecsSinceEpoch() : 0, span = 12 * 3600;
        for (const ChargeEntry &e : b.history) {
            const double x = 1.0 - static_cast<double>(end - static_cast<qint64>(e.time)) / static_cast<double>(span);
            if (x < 0 || x > 1)
                continue;
            values << e.percent;
            xs << x;
        }
        blocks << graph(QStringLiteral("battery"), tr("Battery (Last 12 hours)"), kArea, 100.0,
                        {QVariantMap{{QStringLiteral("values"), values}, {QStringLiteral("xs"), xs},
                                     {QStringLiteral("color"), QStringLiteral("activityGraphBattery")}}});
        break;
    }
    case Tab::Disk: {
        const DiskSnapshot &d = s.diskTotal;
        const bool ok = known && !s.disks.empty();
        const bool io = m_diskMode == QLatin1String("io");
        auto count = [&](double v) { return formatCount(ok ? v : -1, m_locale); };
        auto bytes = [&](double v) { return formatBytes(ok ? v : -1, m_locale); };
        blocks << figures({figure(tr("Reads in:"), count(static_cast<double>(d.reads))),
                           figure(tr("Writes out:"), count(static_cast<double>(d.writes))),
                           figure(tr("Reads in/sec:"), count(d.readsPerSec), io ? QStringLiteral("activityGraphRead") : QString()),
                           figure(tr("Writes out/sec:"), count(d.writesPerSec), io ? QStringLiteral("activityGraphWrite") : QString())});
        const History &up = io ? m_diskReads : m_diskReadBytes, &down = io ? m_diskWrites : m_diskWriteBytes;
        QVariantMap g = graph(QStringLiteral("disk"), io ? tr("Reads and Writes") : tr("Data"), kMirrored,
                              scaleFor(std::max(up.peak(), down.peak())),
                              {series(up, QStringLiteral("activityGraphRead")), series(down, QStringLiteral("activityGraphWrite"))});
        g.insert(QStringLiteral("modes"), QVariantList{mode(QStringLiteral("io"), tr("IO")), mode(QStringLiteral("data"), tr("Data"))});
        g.insert(QStringLiteral("mode"), m_diskMode);
        blocks << g;
        blocks << figures({figure(tr("Data read:"), bytes(static_cast<double>(d.bytesRead))),
                           figure(tr("Data written:"), bytes(static_cast<double>(d.bytesWritten))),
                           figure(tr("Data read/sec:"), bytes(d.readBytesPerSec), io ? QString() : QStringLiteral("activityGraphRead")),
                           figure(tr("Data written/sec:"), bytes(d.writeBytesPerSec), io ? QString() : QStringLiteral("activityGraphWrite"))});
        break;
    }
    case Tab::Network: {
        const NetSnapshot &n = s.netTotal;
        const bool ok = known && !s.interfaces.empty();
        const bool packets = m_networkMode == QLatin1String("packets");
        auto count = [&](double v) { return formatCount(ok ? v : -1, m_locale); };
        auto bytes = [&](double v) { return formatBytes(ok ? v : -1, m_locale); };
        blocks << figures({figure(tr("Packets in:"), count(static_cast<double>(n.packetsIn))),
                           figure(tr("Packets out:"), count(static_cast<double>(n.packetsOut))),
                           figure(tr("Packets in/sec:"), count(n.packetsInPerSec), packets ? QStringLiteral("activityGraphIn") : QString()),
                           figure(tr("Packets out/sec:"), count(n.packetsOutPerSec), packets ? QStringLiteral("activityGraphOut") : QString())});
        const History &up = packets ? m_netPacketsIn : m_netBytesIn, &down = packets ? m_netPacketsOut : m_netBytesOut;
        QVariantMap g = graph(QStringLiteral("network"), packets ? tr("Packets") : tr("Data"), kMirrored,
                              scaleFor(std::max(up.peak(), down.peak())),
                              {series(up, QStringLiteral("activityGraphIn")), series(down, QStringLiteral("activityGraphOut"))});
        g.insert(QStringLiteral("modes"), QVariantList{mode(QStringLiteral("packets"), tr("Packets")), mode(QStringLiteral("data"), tr("Data"))});
        g.insert(QStringLiteral("mode"), m_networkMode);
        blocks << g;
        blocks << figures({figure(tr("Data received:"), bytes(static_cast<double>(n.bytesIn))),
                           figure(tr("Data sent:"), bytes(static_cast<double>(n.bytesOut))),
                           figure(tr("Data received/sec:"), bytes(n.bytesInPerSec), packets ? QString() : QStringLiteral("activityGraphIn")),
                           figure(tr("Data sent/sec:"), bytes(n.bytesOutPerSec), packets ? QString() : QStringLiteral("activityGraphOut"))});
        break;
    }
    }
    m_blocks = blocks;
    emit changed();
}

} // namespace activity
