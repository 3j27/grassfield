// The summary under the table (spec AM5, AM29, AM32 to AM35, AM39, AM42, AM44; ADR-0038 step 2b): each tab's figures and
// graphs, the graphs' history and its gaps, the Disk and Network pop-ups and what they remember, and the battery from UPower.
#include "activitystate.h"
#include "battery.h"
#include "summary.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTimeZone>

#include <gtest/gtest.h>

#include <cmath>

using namespace activity;

namespace {

const QLocale kC(QLocale::C);

QVariantMap block(const Summary &s, int i)
{
    return s.blocks().at(i).toMap();
}

// The figure labelled `label` in the tab's blocks: {label, value, swatch}, or an empty map.
QVariantMap figureOf(const Summary &s, const QString &label)
{
    for (const QVariant &b : s.blocks()) {
        for (const QVariant &r : b.toMap().value(QStringLiteral("rows")).toList()) {
            if (r.toMap().value(QStringLiteral("label")).toString() == label)
                return r.toMap();
        }
    }
    return {};
}

QVariantMap graphOf(const Summary &s, const QString &key)
{
    for (const QVariant &b : s.blocks()) {
        if (b.toMap().value(QStringLiteral("key")).toString() == key)
            return b.toMap();
    }
    return {};
}

QList<double> values(const QVariantMap &graph, int series)
{
    QList<double> out;
    for (const QVariant &v : graph.value(QStringLiteral("series")).toList().at(series).toMap().value(QStringLiteral("values")).toList())
        out << v.toDouble();
    return out;
}

Snapshot cpuSample(double system, double user, double idle)
{
    Snapshot s;
    s.system.cpuOk = true;
    s.system.systemShare = system;
    s.system.userShare = user;
    s.system.idleShare = idle;
    s.system.tasks = 1734;
    s.system.processes = 412;
    return s;
}

} // namespace

// Review of steps 3 to 5: off screen the histories take the samples (the Dock's graph reads them) and the blocks are built
// again only when the window shows.
TEST(Summary, OffScreenTheBlocksWait)
{
    Summary s;
    s.setCapacity(10);
    Snapshot snap;
    snap.system.cpuOk = true;
    snap.system.userShare = 0.2;
    snap.system.systemShare = 0.1;
    s.addSample(snap);
    QSignalSpy changed(&s, &Summary::changed);
    s.setLive(false);
    s.addSample(snap);
    s.addSample(snap);
    EXPECT_EQ(changed.count(), 0);
    EXPECT_EQ(s.dockTileSamples(QStringLiteral("cpu-history"), 32).size(), 3);
    s.setLive(true);
    EXPECT_EQ(changed.count(), 1);
    s.setLive(true); // nothing new: nothing built
    EXPECT_EQ(changed.count(), 1);
}

TEST(Summary, AHistoryKeepsItsLastSamplesAndItsGaps)
{
    History h;
    h.setCapacity(3);
    for (double v : {1.0, -1.0, 4.0, 2.0})
        h.add(v);
    EXPECT_EQ(h.values(), (std::deque<double>{-1, 4, 2}));
    EXPECT_DOUBLE_EQ(h.peak(), 4.0);
    h.add(NAN); // never a value: a gap
    EXPECT_EQ(h.values().back(), -1);
    h.setCapacity(1);
    EXPECT_EQ(h.values().size(), 1u);
}

// AM29: System, User and Idle with their swatches, the CPU Load graph stacked, Threads and Processes; a sample without the
// shares is a gap in the graph and "—" in the figures.
TEST(Summary, CpuFiguresAndItsLoadGraph)
{
    Summary s;
    s.setLocale(kC);
    s.setCapacity(4);
    QSignalSpy changed(&s, &Summary::changed);
    s.addSample(cpuSample(-1, -1, -1)); // the first sample: no rates
    s.addSample(cpuSample(0.05, 0.25, 0.70));
    EXPECT_EQ(changed.count(), 2);
    ASSERT_EQ(s.blocks().size(), 3);
    EXPECT_EQ(block(s, 0).value(QStringLiteral("kind")).toString(), QStringLiteral("figures"));
    EXPECT_EQ(figureOf(s, QStringLiteral("System:")).value(QStringLiteral("value")).toString(), QStringLiteral("5.0%"));
    EXPECT_EQ(figureOf(s, QStringLiteral("System:")).value(QStringLiteral("swatch")).toString(), QStringLiteral("activityGraphSystem"));
    EXPECT_EQ(figureOf(s, QStringLiteral("User:")).value(QStringLiteral("value")).toString(), QStringLiteral("25.0%"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Idle:")).value(QStringLiteral("value")).toString(), QStringLiteral("70.0%"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Idle:")).value(QStringLiteral("swatch")).toString(), QString());
    EXPECT_EQ(figureOf(s, QStringLiteral("Threads:")).value(QStringLiteral("value")).toString(), QStringLiteral("1734"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Processes:")).value(QStringLiteral("value")).toString(), QStringLiteral("412"));
    const QVariantMap load = graphOf(s, QStringLiteral("cpu"));
    EXPECT_EQ(load.value(QStringLiteral("style")).toString(), QStringLiteral("stacked"));
    EXPECT_DOUBLE_EQ(load.value(QStringLiteral("max")).toDouble(), 1.0);
    EXPECT_EQ(values(load, 0), (QList<double>{-1, 0.05}));
    EXPECT_EQ(values(load, 1), (QList<double>{-1, 0.25}));

    Summary none;
    none.setLocale(kC);
    none.addSample(Snapshot{});
    EXPECT_EQ(figureOf(none, QStringLiteral("System:")).value(QStringLiteral("value")).toString(), QStringLiteral("—"));
    EXPECT_EQ(figureOf(none, QStringLiteral("Threads:")).value(QStringLiteral("value")).toString(), QStringLiteral("—"));
}

// AM32 to AM35: the Memory Pressure bars with their levels, then the seven figures in bytes.
TEST(Summary, MemoryFiguresAndItsPressureGraph)
{
    Summary s;
    s.setLocale(kC);
    s.setCapacity(10);
    s.setTab(Tab::Memory);
    Snapshot snap;
    MemorySummary &m = snap.system.memory;
    m.ok = true;
    m.physical = 16000000000;
    m.used = 8000000000;
    m.app = 5000000000;
    m.wired = 2000000000;
    m.compressed = 1000000000;
    m.cached = 3000000000;
    m.swapUsed = 0;
    m.inUse = 0.5;
    m.level = PressureLevel::Warning;
    s.addSample(snap);
    m.inUse = 0.9;
    m.level = PressureLevel::Critical;
    s.addSample(snap);
    const QVariantMap pressure = block(s, 0);
    EXPECT_EQ(pressure.value(QStringLiteral("key")).toString(), QStringLiteral("pressure"));
    EXPECT_EQ(pressure.value(QStringLiteral("style")).toString(), QStringLiteral("bars"));
    EXPECT_EQ(values(pressure, 0), (QList<double>{0.5, 0.9}));
    EXPECT_EQ(pressure.value(QStringLiteral("levels")).toList(), (QVariantList{1.0, 2.0}));
    EXPECT_EQ(pressure.value(QStringLiteral("levelColors")).toStringList(),
              (QStringList{QStringLiteral("activityPressureGreen"), QStringLiteral("activityPressureYellow"), QStringLiteral("activityPressureRed")}));
    EXPECT_EQ(figureOf(s, QStringLiteral("Physical Memory:")).value(QStringLiteral("value")).toString(), QStringLiteral("16.0 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Memory Used:")).value(QStringLiteral("value")).toString(), QStringLiteral("8.00 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("App Memory:")).value(QStringLiteral("value")).toString(), QStringLiteral("5.00 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Wired Memory:")).value(QStringLiteral("value")).toString(), QStringLiteral("2.00 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Compressed:")).value(QStringLiteral("value")).toString(), QStringLiteral("1.00 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Cached Files:")).value(QStringLiteral("value")).toString(), QStringLiteral("3.00 GB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Swap Used:")).value(QStringLiteral("value")).toString(), QStringLiteral("0 bytes"));
}

// AM42: the pop-up chooses IO or Data; the graph and the swatches follow it. Every tab's graph keeps its history while
// another tab is shown (2b).
TEST(Summary, DiskGraphShowsIoOrDataAndKeepsItsHistory)
{
    Summary s;
    s.setLocale(kC);
    s.setCapacity(5);
    Snapshot snap;
    DiskSnapshot d;
    d.name = "nvme0n1";
    snap.system.disks.push_back(d);
    DiskSnapshot &t = snap.system.diskTotal;
    t.reads = 1000;
    t.writes = 2000;
    t.bytesRead = 5000000;
    t.bytesWritten = 7000000;
    t.readsPerSec = 3;
    t.writesPerSec = 9;
    t.readBytesPerSec = 4000;
    t.writeBytesPerSec = 12000;
    s.addSample(snap); // on the CPU tab
    s.setTab(Tab::Disk);
    QVariantMap g = graphOf(s, QStringLiteral("disk"));
    EXPECT_EQ(g.value(QStringLiteral("style")).toString(), QStringLiteral("mirrored"));
    EXPECT_EQ(g.value(QStringLiteral("mode")).toString(), QStringLiteral("io"));
    EXPECT_EQ(values(g, 0), (QList<double>{3}));
    EXPECT_EQ(values(g, 1), (QList<double>{9}));
    EXPECT_NEAR(g.value(QStringLiteral("max")).toDouble(), 9.9, 1e-9);
    EXPECT_EQ(figureOf(s, QStringLiteral("Reads in/sec:")).value(QStringLiteral("swatch")).toString(), QStringLiteral("activityGraphRead"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Data read/sec:")).value(QStringLiteral("swatch")).toString(), QString());
    EXPECT_EQ(figureOf(s, QStringLiteral("Reads in:")).value(QStringLiteral("value")).toString(), QStringLiteral("1000"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Data written:")).value(QStringLiteral("value")).toString(), QStringLiteral("7.00 MB"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Data written/sec:")).value(QStringLiteral("value")).toString(), QStringLiteral("12 KB"));

    s.setDiskMode(QStringLiteral("data"));
    g = graphOf(s, QStringLiteral("disk"));
    EXPECT_EQ(g.value(QStringLiteral("mode")).toString(), QStringLiteral("data"));
    EXPECT_EQ(values(g, 0), (QList<double>{4000}));
    EXPECT_EQ(figureOf(s, QStringLiteral("Reads in/sec:")).value(QStringLiteral("swatch")).toString(), QString());
    EXPECT_EQ(figureOf(s, QStringLiteral("Data read/sec:")).value(QStringLiteral("swatch")).toString(), QStringLiteral("activityGraphRead"));
    s.setDiskMode(QStringLiteral("nonsense")); // anything else is IO
    EXPECT_EQ(graphOf(s, QStringLiteral("disk")).value(QStringLiteral("mode")).toString(), QStringLiteral("io"));

    // No whole physical disk (a container): every figure is "—".
    Summary none;
    none.setLocale(kC);
    none.setTab(Tab::Disk);
    none.addSample(Snapshot{});
    EXPECT_EQ(figureOf(none, QStringLiteral("Reads in:")).value(QStringLiteral("value")).toString(), QStringLiteral("—"));
}

// AM44: Packets or Data, received above and sent below.
TEST(Summary, NetworkGraphShowsPacketsOrData)
{
    Summary s;
    s.setLocale(kC);
    s.setCapacity(5);
    s.setTab(Tab::Network);
    Snapshot snap;
    snap.system.interfaces.push_back(NetSnapshot{});
    NetSnapshot &n = snap.system.netTotal;
    n.packetsIn = 40;
    n.packetsOut = 30;
    n.bytesIn = 50000;
    n.bytesOut = 7000;
    n.packetsInPerSec = 4;
    n.packetsOutPerSec = 3;
    n.bytesInPerSec = 5000;
    n.bytesOutPerSec = 700;
    s.addSample(snap);
    QVariantMap g = graphOf(s, QStringLiteral("network"));
    EXPECT_EQ(values(g, 0), (QList<double>{4}));
    EXPECT_EQ(values(g, 1), (QList<double>{3}));
    EXPECT_EQ(g.value(QStringLiteral("series")).toList().at(0).toMap().value(QStringLiteral("color")).toString(), QStringLiteral("activityGraphIn"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Packets in/sec:")).value(QStringLiteral("swatch")).toString(), QStringLiteral("activityGraphIn"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Data received:")).value(QStringLiteral("value")).toString(), QStringLiteral("50 KB"));
    s.setNetworkMode(QStringLiteral("data"));
    g = graphOf(s, QStringLiteral("network"));
    EXPECT_EQ(values(g, 0), (QList<double>{5000}));
    EXPECT_EQ(values(g, 1), (QList<double>{700}));
    EXPECT_EQ(figureOf(s, QStringLiteral("Data sent/sec:")).value(QStringLiteral("swatch")).toString(), QStringLiteral("activityGraphOut"));
}

// AM39: the Energy Impact graph takes only the samples that computed the sum; without a battery it is all the tab shows.
TEST(Summary, EnergyGraphAndTheBattery)
{
    Summary s;
    s.setLocale(kC);
    s.setCapacity(5);
    s.setTab(Tab::Energy);
    Snapshot snap;
    snap.energyImpact = 12.5;
    s.addSample(snap);
    snap.energyImpact = -1; // a sample of another tab: not an Energy sample
    s.addSample(snap);
    snap.energyImpact = 30;
    s.addSample(snap);
    ASSERT_EQ(s.blocks().size(), 1);
    QVariantMap g = graphOf(s, QStringLiteral("energy"));
    EXPECT_EQ(values(g, 0), (QList<double>{12.5, 30}));
    EXPECT_NEAR(g.value(QStringLiteral("max")).toDouble(), 33.0, 1e-9);

    const QDateTime now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
    BatteryState b;
    b.present = true;
    b.percent = 81.6;
    b.charge = BatteryCharge::Discharging;
    b.timeToEmpty = 2 * 3600 + 5 * 60;
    b.sourceSince = now.toSecsSinceEpoch() - 3 * 3600 - 7 * 60;
    b.history = {{static_cast<uint>(now.toSecsSinceEpoch() - 13 * 3600), 100, 4}, // older than twelve hours: left out
                 {static_cast<uint>(now.toSecsSinceEpoch() - 6 * 3600), 95, 2},
                 {static_cast<uint>(now.toSecsSinceEpoch()), 81.6, 2}};
    s.setBattery(b, now);
    ASSERT_EQ(s.blocks().size(), 3);
    EXPECT_EQ(figureOf(s, QStringLiteral("Remaining charge:")).value(QStringLiteral("value")).toString(), QStringLiteral("82%"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Time remaining:")).value(QStringLiteral("value")).toString(), QStringLiteral("2:05"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Time on battery:")).value(QStringLiteral("value")).toString(), QStringLiteral("3:07"));
    g = graphOf(s, QStringLiteral("battery"));
    EXPECT_EQ(values(g, 0), (QList<double>{95, 81.6}));
    const QVariantList xs = g.value(QStringLiteral("series")).toList().at(0).toMap().value(QStringLiteral("xs")).toList();
    ASSERT_EQ(xs.size(), 2);
    EXPECT_DOUBLE_EQ(xs.at(0).toDouble(), 0.5);
    EXPECT_DOUBLE_EQ(xs.at(1).toDouble(), 1.0);
    // The integrator's review of 91dcb63: UPower says nothing new for ten minutes, the samples go on; the time on battery
    // counts and the graph slides with them. Six hours later the first entry has slid out.
    s.addSample(Snapshot{}, now.addSecs(600));
    EXPECT_EQ(figureOf(s, QStringLiteral("Time on battery:")).value(QStringLiteral("value")).toString(), QStringLiteral("3:17"));
    g = graphOf(s, QStringLiteral("battery"));
    const QVariantList slid = g.value(QStringLiteral("series")).toList().at(0).toMap().value(QStringLiteral("xs")).toList();
    ASSERT_EQ(slid.size(), 2);
    EXPECT_DOUBLE_EQ(slid.at(0).toDouble(), 0.5 - 600.0 / 43200);
    EXPECT_DOUBLE_EQ(slid.at(1).toDouble(), 1.0 - 600.0 / 43200);
    s.addSample(Snapshot{}, now.addSecs(6 * 3600 + 60));
    EXPECT_EQ(values(graphOf(s, QStringLiteral("battery")), 0), (QList<double>{81.6}));

    b.timeToEmpty = 0; // UPower still estimating
    s.setBattery(b, now);
    EXPECT_EQ(figureOf(s, QStringLiteral("Time remaining:")).value(QStringLiteral("value")).toString(), QStringLiteral("Calculating…"));
    b.charge = BatteryCharge::Charging;
    b.timeToFull = 45 * 60;
    b.sourceSince = 0; // the change is older than the history
    s.setBattery(b, now);
    EXPECT_EQ(figureOf(s, QStringLiteral("Time until full:")).value(QStringLiteral("value")).toString(), QStringLiteral("0:45"));
    EXPECT_EQ(figureOf(s, QStringLiteral("Time on AC:")).value(QStringLiteral("value")).toString(), QStringLiteral("—"));
    b.charge = BatteryCharge::Full;
    s.setBattery(b, now);
    EXPECT_FALSE(figureOf(s, QStringLiteral("Battery Is Charged")).isEmpty());
    EXPECT_TRUE(figureOf(s, QStringLiteral("Time until full:")).isEmpty());
    b.present = false;
    s.setBattery(b, now);
    EXPECT_EQ(s.blocks().size(), 1);
}

TEST(Battery, TheDisplayDeviceAndTheHistory)
{
    BatteryState b;
    applyDeviceProperties({{QStringLiteral("IsPresent"), true}, {QStringLiteral("Type"), 2u}, {QStringLiteral("Percentage"), 64.5},
                           {QStringLiteral("State"), 1u}, {QStringLiteral("TimeToFull"), qlonglong(1800)}},
                          b);
    EXPECT_TRUE(b.present);
    EXPECT_DOUBLE_EQ(b.percent, 64.5);
    EXPECT_EQ(b.charge, BatteryCharge::Charging);
    EXPECT_EQ(b.timeToFull, 1800);
    // A desktop: UPower's display device is a line power or absent.
    applyDeviceProperties({{QStringLiteral("IsPresent"), true}, {QStringLiteral("Type"), 1u}, {QStringLiteral("Percentage"), 0.0}}, b);
    EXPECT_FALSE(b.present);
    EXPECT_LT(b.percent, 0);
    applyDeviceProperties({}, b);
    EXPECT_FALSE(b.present);

    EXPECT_TRUE(onBattery(BatteryCharge::Discharging));
    EXPECT_TRUE(onBattery(BatteryCharge::PendingDischarge));
    EXPECT_FALSE(onBattery(BatteryCharge::Full));
    // Unplugged at 200 after charging, an entry of unknown state in between: on battery since 200.
    const QList<ChargeEntry> h{{100, 90, 1}, {150, 95, 4}, {200, 95, 2}, {250, 94, 0}, {300, 90, 2}};
    EXPECT_EQ(lastSourceChange(h, true), 200);
    EXPECT_EQ(lastSourceChange(h, false), 0);              // the history ends on battery: on AC since after its end, unknown
    EXPECT_EQ(lastSourceChange({{100, 90, 2}}, true), 0);  // the whole history on battery: older than it
    EXPECT_EQ(lastSourceChange({}, true), 0);

    EXPECT_EQ(batteryPath({QStringLiteral("/org/freedesktop/UPower/devices/line_power_AC"),
                           QStringLiteral("/org/freedesktop/UPower/devices/mouse_hidpp_battery_0"),
                           QStringLiteral("/org/freedesktop/UPower/devices/battery_BAT0")}),
              QStringLiteral("/org/freedesktop/UPower/devices/battery_BAT0"));
    EXPECT_EQ(batteryPath({QStringLiteral("/org/freedesktop/UPower/devices/line_power_AC")}), QString());
}

// What the Disk and Network pop-ups show is remembered in activity.json; anything else reads as the default.
TEST(ActivityState, TheGraphsChoiceIsRemembered)
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("activity.json"));
    ActivityState s = defaultState();
    EXPECT_EQ(s.diskGraph, QStringLiteral("io"));
    EXPECT_EQ(s.networkGraph, QStringLiteral("packets"));
    s.diskGraph = QStringLiteral("data");
    s.networkGraph = QStringLiteral("data");
    ASSERT_TRUE(writeState(path, s));
    const ActivityState back = readState(path);
    EXPECT_EQ(back.diskGraph, QStringLiteral("data"));
    EXPECT_EQ(back.networkGraph, QStringLiteral("data"));

    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(QJsonDocument(QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("diskGraph"), QStringLiteral("packets")},
                                      {QStringLiteral("networkGraph"), 3}})
                .toJson());
    f.close();
    const ActivityState wrong = readState(path);
    EXPECT_EQ(wrong.diskGraph, QStringLiteral("io"));
    EXPECT_EQ(wrong.networkGraph, QStringLiteral("packets"));
}

// AM74 (steps 3 to 5): the Dock icon, Efficiency Mode's "Don't ask again", App History's period and the other windows'
// sizes are remembered; a value of the wrong kind reads as the default.
TEST(ActivityState, TheLaterChoicesAreRemembered)
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("activity.json"));
    ActivityState s = defaultState();
    EXPECT_TRUE(s.askEfficiency);
    EXPECT_EQ(s.appHistoryPeriod, QStringLiteral("12h"));
    s.dockIcon = QStringLiteral("cpu-history");
    s.askEfficiency = false;
    s.appHistoryPeriod = QStringLiteral("30d");
    s.windows.insert(QStringLiteral("performance"), QSize(900, 640));
    s.windows.insert(QStringLiteral("cpuUsage"), QSize(300, 200)); // not a kind whose size is kept
    ASSERT_TRUE(writeState(path, s));
    const ActivityState back = readState(path);
    EXPECT_EQ(back.dockIcon, QStringLiteral("cpu-history"));
    EXPECT_FALSE(back.askEfficiency);
    EXPECT_EQ(back.appHistoryPeriod, QStringLiteral("30d"));
    EXPECT_EQ(back.windows.value(QStringLiteral("performance")), QSize(900, 640));
    EXPECT_FALSE(back.windows.contains(QStringLiteral("cpuUsage")));

    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(QJsonDocument(QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("dockIcon"), QStringLiteral("gpu")},
                                      {QStringLiteral("askEfficiency"), QStringLiteral("no")},
                                      {QStringLiteral("appHistoryPeriod"), QStringLiteral("1y")},
                                      {QStringLiteral("windows"), QJsonObject{{QStringLiteral("appHistory"),
                                                                               QJsonObject{{QStringLiteral("width"), 50}, {QStringLiteral("height"), 400}}}}}})
                .toJson());
    f.close();
    const ActivityState wrong = readState(path);
    EXPECT_EQ(wrong.dockIcon, QStringLiteral("icon"));
    EXPECT_TRUE(wrong.askEfficiency);
    EXPECT_EQ(wrong.appHistoryPeriod, QStringLiteral("12h"));
    EXPECT_TRUE(wrong.windows.isEmpty()); // too narrow: the token size instead
}
