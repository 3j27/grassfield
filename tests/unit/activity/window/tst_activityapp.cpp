// The window's backend (spec AM8, AM9, AM10, AM15, AM74; ADR-0038 step 2a): samples only while the window is shown, no rate
// drawn across a gap, the columns and the sort of each tab, and activity.json.
#include "../fixture.h"
#include "activityapp.h"

#include <QFile>
#include <QSignalSpy>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace {

constexpr unsigned kMe = 1000;

Options fixtureOptions(const Fixture &f)
{
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    o.uid = kMe;
    o.clockTicks = 100;
    o.maxKeptFiles = 4096;
    return o;
}

std::string nul(std::initializer_list<const char *> words)
{
    std::string s;
    for (const char *w : words) {
        s += w;
        s += '\0';
    }
    return s;
}

// grassfield.json comes from an empty folder: the tests never read the machine's settings.
struct Isolated {
    QTemporaryDir config, state;
    Isolated()
    {
        qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8());
    }
    QString statePath() const { return state.path() + QStringLiteral("/activity.json"); }
};

QStringList keys(const QVariantList &columns)
{
    QStringList list;
    for (const QVariant &c : columns)
        list << c.toMap().value(QStringLiteral("key")).toString();
    return list;
}

bool waitSample(ActivityApp &app)
{
    QSignalSpy spy(&app, &ActivityApp::sampled);
    return spy.wait(5000);
}

} // namespace

TEST(ActivityApp, SamplesOnlyWhileShownAndNoRateAcrossAGap)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    f.process(101, "other", kMe, 50, 1, nul({"other"}), "/");
    Isolated iso;
    ActivityApp app(fixtureOptions(f), iso.statePath());
    EXPECT_EQ(app.processSamples(), 0); // nothing samples while nothing is shown (AM-P3)

    app.setWindowShown(true);
    ASSERT_TRUE(waitSample(app));
    EXPECT_EQ(app.processSamples(), 1);
    EXPECT_EQ(app.processTable().count(), 2);
    for (const TableRow &r : app.processTable().shownRows())
        EXPECT_LT(r.process.cpuPercent, 0); // a first sample has no rate

    app.setTab(QStringLiteral("memory")); // another tab samples at once
    ASSERT_TRUE(waitSample(app));
    for (const TableRow &r : app.processTable().shownRows())
        EXPECT_GE(r.process.cpuPercent, 0);

    app.setWindowShown(false);
    const int before = app.processSamples();
    QSignalSpy spy(&app, &ActivityApp::sampled);
    EXPECT_FALSE(spy.wait(300));
    app.setTab(QStringLiteral("cpu")); // hidden: a tab change samples nothing
    EXPECT_FALSE(spy.wait(300));
    EXPECT_EQ(app.processSamples(), before);

    // Back on screen: a sample at once, its rates "—" (AM8).
    app.setWindowShown(true);
    ASSERT_TRUE(waitSample(app));
    EXPECT_EQ(app.processSamples(), before + 1);
    for (const TableRow &r : app.processTable().shownRows())
        EXPECT_LT(r.process.cpuPercent, 0);
}

TEST(ActivityApp, ColumnsAndSortPerTab)
{
    Fixture f;
    Isolated iso;
    {
        ActivityApp app(fixtureOptions(f), iso.statePath());
        EXPECT_EQ(keys(app.shownColumns()),
                  (QStringList{"name", "cpuPercent", "cpuTime", "threads", "gpuPercent", "gpuTime", "pid", "user"}));
        // AM15: an optional column comes in at its place in the tab's order; the name cannot be hidden.
        app.setColumnShown(QStringLiteral("wakeUps"), true);
        app.setColumnShown(QStringLiteral("name"), false);
        app.setColumnShown(QStringLiteral("gpuTime"), false);
        app.setColumnShown(QStringLiteral("memory"), true); // not a CPU column
        EXPECT_EQ(keys(app.shownColumns()), (QStringList{"name", "cpuPercent", "cpuTime", "threads", "wakeUps", "gpuPercent", "pid", "user"}));
        // AM10: numbers sort from the largest, text from A; the same header again reverses.
        app.sortBy(QStringLiteral("pid"));
        EXPECT_EQ(app.sortKey(), "pid");
        EXPECT_TRUE(app.sortDescending());
        app.sortBy(QStringLiteral("pid"));
        EXPECT_FALSE(app.sortDescending());
        app.sortBy(QStringLiteral("user"));
        EXPECT_FALSE(app.sortDescending());
        app.setColumnWidth(QStringLiteral("user"), 120);
        // Each tab its own (AM4).
        app.setTab(QStringLiteral("disk"));
        EXPECT_EQ(keys(app.shownColumns()), (QStringList{"name", "bytesWritten", "bytesRead", "pid", "user"}));
        EXPECT_EQ(app.sortKey(), "bytesWritten");
        app.setInterval(2);
        app.setInterval(3); // not one of AM9's
        EXPECT_EQ(app.interval(), 2);
        app.setView(QStringLiteral("mine"));
    } // closing writes what is pending

    // AM74: what the window remembers.
    const ActivityState s = readState(iso.statePath());
    EXPECT_EQ(s.tab, Tab::Disk);
    EXPECT_EQ(s.view, View::Mine);
    EXPECT_EQ(s.interval, 2);
    const TabState &cpu = s.tabs.at(Tab::Cpu);
    EXPECT_EQ(cpu.columns, (std::vector<Column>{Column::Name, Column::CpuPercent, Column::CpuTime, Column::Threads, Column::WakeUps,
                                                Column::GpuPercent, Column::Pid, Column::User}));
    EXPECT_EQ(cpu.sort, Column::User);
    EXPECT_FALSE(cpu.descending);
    EXPECT_EQ(cpu.widths.value(QStringLiteral("user")), 120);
    ActivityApp again(fixtureOptions(f), iso.statePath());
    EXPECT_EQ(again.tab(), "disk");
    EXPECT_EQ(again.view(), "mine");
}

TEST(ActivityState, ABrokenFileIsSetAside)
{
    QTemporaryDir dir;
    const QString path = dir.path() + QStringLiteral("/activity.json");
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("{\"version\": 7}");
    f.close();
    const ActivityState s = readState(path);
    EXPECT_EQ(s.tab, Tab::Cpu); // the defaults
    EXPECT_FALSE(QFile::exists(path));
    EXPECT_TRUE(QFile::exists(path + QStringLiteral(".bad")));

    // Values out of range take their defaults; a column of another tab or twice is dropped; the name comes first.
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(R"({"version": 1, "interval": 7, "tab": "gpu", "view": "selected", "window": {"width": 5, "height": 900},
               "tabs": {"cpu": {"columns": ["pid", "memory", "pid", "cpuPercent"], "sort": "memory", "widths": {"pid": 9000}}}})");
    f.close();
    const ActivityState t = readState(path);
    EXPECT_EQ(t.interval, 5);
    EXPECT_EQ(t.tab, Tab::Cpu);
    EXPECT_EQ(t.view, View::All); // Selected Processes holds one run's rows
    EXPECT_EQ(t.width, 0);
    const TabState &cpu = t.tabs.at(Tab::Cpu);
    EXPECT_EQ(cpu.columns, (std::vector<Column>{Column::Name, Column::Pid, Column::CpuPercent}));
    EXPECT_EQ(cpu.sort, Column::CpuPercent);
    EXPECT_TRUE(cpu.widths.isEmpty());
    EXPECT_TRUE(QFile::exists(path)); // a readable version 1 file stays where it is
}
