// The window's backend (spec AM8, AM9, AM10, AM15, AM74; ADR-0038 step 2a): samples only while the window is shown, no rate
// drawn across a gap, the columns and the sort of each tab, and activity.json.
#include "../fixture.h"
#include "activityapp.h"
#include "samplerworker.h"

#include <QDBusConnection>
#include <QElapsedTimer>
#include <QFile>
#include <QMutex>
#include <QPointer>
#include <QProcess>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>

#include <gtest/gtest.h>

#include <sys/stat.h>

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

// AM8: back on screen after a gap, the first sample's rates show "—", so the next comes a second later, then the interval.
TEST(ActivityApp, AfterAGapTheSecondSampleComesASecondLater)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    Isolated iso;
    ActivityApp app(fixtureOptions(f), iso.statePath()); // Normally (5 sec)
    app.setWindowShown(true);
    ASSERT_TRUE(waitSample(app));
    app.setWindowShown(false);
    app.setWindowShown(true);
    ASSERT_TRUE(waitSample(app)); // at once
    QElapsedTimer t;
    t.start();
    ASSERT_TRUE(waitSample(app));
    EXPECT_LT(t.elapsed(), 2500); // a second later, not five
    for (const TableRow &r : app.processTable().shownRows())
        EXPECT_GE(r.process.cpuPercent, 0);
    QSignalSpy spy(&app, &ActivityApp::sampled);
    EXPECT_FALSE(spy.wait(2500)); // then the interval again
}

// One sample at a time: what asks for one while one runs (a tab, a column) gets a single one more, with what it asked.
TEST(ActivityApp, RequestsWhileASampleRunsMakeOneMore)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    Isolated iso;
    ActivityApp app(fixtureOptions(f), iso.statePath());
    QSignalSpy requests(&app, &ActivityApp::sampleRequested);
    QSignalSpy samples(&app, &ActivityApp::sampled);
    app.setWindowShown(true); // the first sample, running on its thread
    app.setTab(QStringLiteral("memory"));
    app.setTab(QStringLiteral("energy"));
    app.setTab(QStringLiteral("disk"));
    ASSERT_TRUE(QTest::qWaitFor([&] { return samples.count() >= 2; }, 5000));
    EXPECT_FALSE(samples.wait(1000)); // no third before the interval
    EXPECT_EQ(samples.count(), 2);
    ASSERT_EQ(requests.count(), 2);
    EXPECT_EQ(requests.last().at(0).toUInt(), readsForColumns(Tab::Disk, tabColumns(Tab::Disk).defaults));
}

// Follow-up 2 (AD32): a pause is told by the update interval set in the window, which reaches the sampler.
TEST(ActivityApp, ThePauseIsToldByTheIntervalSet)
{
    Fixture f;
    for (int pid = 100; pid < 110; ++pid)
        f.process(pid, "m", kMe, 0, 1, nul({"m"}), "/");
    Isolated iso;
    {
        ActivityApp app(fixtureOptions(f), iso.statePath());
        app.setInterval(2);
        QSignalSpy requests(&app, &ActivityApp::sampleRequested);
        app.setWindowShown(true);
        ASSERT_GE(requests.count(), 1);
        EXPECT_DOUBLE_EQ(requests.first().at(1).toDouble(), 2.0);
        ASSERT_TRUE(waitSample(app));
    }

    SamplerWorker worker(fixtureOptions(f)); // Normally (5 sec) until told otherwise
    std::vector<SnapshotPtr> got;
    QObject::connect(&worker, &SamplerWorker::sampled, [&](const SnapshotPtr &s, unsigned) { got.push_back(s); });
    const unsigned memory = readsForTab(Tab::Memory);
    worker.sample(memory, 0.1, false);
    QTest::qWait(300); // three intervals of a tenth of a second: a pause
    worker.sample(memory, 0.1, false);
    worker.sample(memory, 5, false); // at once: no pause at 5 sec
    ASSERT_EQ(got.size(), 3u);
    EXPECT_EQ(got[1]->counters.statusReads, 10u); // every process
    EXPECT_EQ(got[2]->counters.statusReads, 2u);  // the turns
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

// AM42, AM44: the pop-ups above the Disk and Network graphs reach the summary and are remembered; anything else is refused.
TEST(ActivityApp, TheGraphsPopUpsAreRemembered)
{
    Fixture f;
    Isolated iso;
    {
        ActivityApp app(fixtureOptions(f), iso.statePath());
        app.setTab(QStringLiteral("network"));
        app.setGraphMode(QStringLiteral("network"), QStringLiteral("data"));
        app.setGraphMode(QStringLiteral("disk"), QStringLiteral("data"));
        app.setGraphMode(QStringLiteral("disk"), QStringLiteral("packets")); // not a Disk mode
        app.setGraphMode(QStringLiteral("cpu"), QStringLiteral("data"));     // no pop-up there
        QString mode;
        for (const QVariant &b : app.summaryModel().blocks()) {
            if (b.toMap().value(QStringLiteral("key")).toString() == QLatin1String("network"))
                mode = b.toMap().value(QStringLiteral("mode")).toString();
        }
        EXPECT_EQ(mode, "data");
    }
    const ActivityState s = readState(iso.statePath());
    EXPECT_EQ(s.networkGraph, "data");
    EXPECT_EQ(s.diskGraph, "data");
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

// AM74: activity.json is the owner's alone (0600), whatever the umask.
TEST(ActivityState, TheFileIsTheOwnersAlone)
{
    QTemporaryDir dir;
    const QString path = dir.path() + QStringLiteral("/activity.json");
    const mode_t old = ::umask(022);
    const bool written = writeState(path, defaultState());
    ::umask(old);
    ASSERT_TRUE(written);
    struct stat st {};
    ASSERT_EQ(::stat(QFile::encodeName(path).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 07777, 0600u);
}

// AD34: launched again while its window is off screen, the app asks the shell's Dock to bring it back; a dev session that
// names no shell never drives the installed one.
TEST(ActivityService, ReopenAsksTheShellsDock)
{
    const QByteArray dev = qgetenv("GRASSFIELD_DEV"), session = qgetenv("GRASSFIELD_SESSION"), shell = qgetenv("GRASSFIELD_SHELL_DIR");
    qunsetenv("GRASSFIELD_SESSION");
    qputenv("GRASSFIELD_DEV", "1");
    qputenv("GRASSFIELD_SHELL_DIR", "/repo/shell");
    EXPECT_EQ(reopenCommand(), (QStringList{QStringLiteral("qs"), QStringLiteral("ipc"), QStringLiteral("-p"), QStringLiteral("/repo/shell"),
                                            QStringLiteral("call"), QStringLiteral("dock"), QStringLiteral("reopen"),
                                            QStringLiteral("org.grassfield.Activity")}));
    qunsetenv("GRASSFIELD_SHELL_DIR");
    EXPECT_TRUE(reopenCommand().isEmpty());
    qunsetenv("GRASSFIELD_DEV");
    EXPECT_EQ(reopenCommand().value(3), QStringLiteral("/usr/share/grassfield/shell")); // the installed shell
    auto restore = [](const char *name, const QByteArray &value) {
        if (value.isNull())
            qunsetenv(name);
        else
            qputenv(name, value);
    };
    restore("GRASSFIELD_DEV", dev);
    restore("GRASSFIELD_SESSION", session);
    restore("GRASSFIELD_SHELL_DIR", shell);
}

namespace {

// A private session bus for one case (dbus-daemon --session), stopped with it; empty where there is no dbus-daemon.
struct PrivateBus {
    QProcess daemon;
    QString address;
    PrivateBus()
    {
        daemon.start(QStringLiteral("dbus-daemon"), {QStringLiteral("--session"), QStringLiteral("--nofork"), QStringLiteral("--print-address=1")});
        if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
            address = QString::fromUtf8(daemon.readLine()).trimmed();
    }
    ~PrivateBus()
    {
        daemon.kill();
        daemon.waitForFinished(3000);
    }
};

} // namespace

// AM1 (the review of PR #47): a launch takes the bus name, or hands its token over to the app that holds it and leaves,
// even when that app answers late (still starting: it answers from its event loop, once its window exists); it runs only
// when the name has no owner left.
TEST(ActivityService, ALaunchTakesTheNameOrHandsItsTokenOverAndLeaves)
{
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QDBusConnection first = QDBusConnection::connectToBus(pb.address, QStringLiteral("first"));
    QDBusConnection second = QDBusConnection::connectToBus(pb.address, QStringLiteral("second"));
    ASSERT_TRUE(first.isConnected() && second.isConnected());

    ActivityService a, b;
    EXPECT_EQ(claimOrHandOver(first, &a, QString(), 1000), Launch::Run);
    // The running app is busy (its thread does not run its event loop, as during a slow start): the launch leaves anyway.
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("token-2"), 300), Launch::Leave);

    // The running app answers: the token reaches it, and the launch leaves.
    first.unregisterService(ActivityService::serviceName());
    first.unregisterObject(QStringLiteral("/org/grassfield/Activity"));
    QThread owner;
    owner.start();
    auto *c = new ActivityService;
    c->moveToThread(&owner);
    QMutex mutex;
    QString got;
    QObject::connect(c, &ActivityService::activateRequested, c, [&](const QString &token) {
        QMutexLocker lock(&mutex);
        got = token;
    }, Qt::DirectConnection);
    EXPECT_EQ(claimOrHandOver(first, c, QString(), 1000), Launch::Run);
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("token-3"), 3000), Launch::Leave);
    {
        QMutexLocker lock(&mutex);
        EXPECT_EQ(got, QStringLiteral("token-3"));
    }
    // The running app quits: the name has no owner left, and the next launch takes it and runs.
    first.unregisterObject(QStringLiteral("/org/grassfield/Activity"));
    first.unregisterService(ActivityService::serviceName());
    owner.quit();
    owner.wait();
    delete c;
    EXPECT_EQ(claimOrHandOver(second, &b, QString(), 1000), Launch::Run);
    second.unregisterService(ActivityService::serviceName());
    second.unregisterObject(QStringLiteral("/org/grassfield/Activity"));
}

// The shell's IPC is killed after its time, as Settings' (the review of PR #47); the process deletes itself.
TEST(ActivityService, AShellCallIsKilledAfterItsTime)
{
    QObject parent;
    QElapsedTimer t;
    t.start();
    QPointer<QProcess> p = runWithTimeout({QStringLiteral("sleep"), QStringLiteral("10")}, QProcessEnvironment::systemEnvironment(), 200, &parent);
    ASSERT_FALSE(p.isNull());
    EXPECT_TRUE(QTest::qWaitFor([&] { return p.isNull(); }, 5000));
    EXPECT_LT(t.elapsed(), 5000);
    EXPECT_EQ(runWithTimeout({}, QProcessEnvironment::systemEnvironment(), 200, &parent), nullptr);
}
