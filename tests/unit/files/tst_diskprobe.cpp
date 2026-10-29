// Questions to the disk off the GUI thread (DiskProbe; ADR-0035 4b-18): Files' sidebar and grassfield-portal's panels never
// wait on a hung mount. A slow disk is a stat function that sleeps for paths under /hung (a read that hangs) or /slow (a
// share slow but answering). Part of files-kio-tests (a scratch home, its own main).
#include "diskprobe.h"
#include "placesmodel.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <gtest/gtest.h>

#include <atomic>

namespace {

constexpr int kHungMs = 1500;
constexpr int kSlowMs = 150;
std::atomic<int> g_hungReads{0};

int slowDisk(const QString &path)
{
    if (path.startsWith(QLatin1String("/hung"))) {
        ++g_hungReads;
        QThread::msleep(kHungMs);
        return 2;
    }
    if (path.startsWith(QLatin1String("/slow"))) {
        QThread::msleep(kSlowMs);
        return 2;
    }
    return DiskProbe::kindOf(path);
}

DiskProbe::Options options(int quietMs = 300, int totalMs = 2000)
{
    return {quietMs, totalMs, slowDisk};
}

bool waitFor(const std::function<bool()> &condition, int ms)
{
    QDeadlineTimer deadline(ms);
    while (!condition() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(5);
    }
    return condition();
}

// One call's answer, waited for.
QHash<QString, int> ask(DiskProbe &probe, const QStringList &paths, qint64 *took = nullptr)
{
    QHash<QString, int> kinds;
    bool done = false;
    int token = -1;
    const auto connection = QObject::connect(&probe, &DiskProbe::answered, [&](int t, const QHash<QString, int> &k) {
        if (t == token) {
            kinds = k;
            done = true;
        }
    });
    QElapsedTimer clock;
    clock.start();
    token = probe.probe(paths);
    EXPECT_FALSE(done) << "never answered from inside the call";
    EXPECT_TRUE(waitFor([&] { return done; }, 10000));
    if (took)
        *took = clock.elapsed();
    QObject::disconnect(connection);
    return kinds;
}

} // namespace

TEST(DiskProbe, SaysWhatEachPathNames)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile file(dir.filePath(QStringLiteral("file")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("folder")));
    ASSERT_TRUE(QFile::link(dir.filePath(QStringLiteral("missing")), dir.filePath(QStringLiteral("dangling"))));
    DiskProbe probe(options());
    const QHash<QString, int> kinds = ask(probe, {dir.filePath(QStringLiteral("file")), dir.filePath(QStringLiteral("folder")),
                                                  dir.filePath(QStringLiteral("dangling")), dir.filePath(QStringLiteral("missing"))});
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("file"))), 1);
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("folder"))), 2);
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("dangling"))), 1); // saving over it asks first
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("missing"))), 0);
}

// Each path's answer is its own (re-review of 65311e0, MAJOR 1): a healthy path queued behind a hung one is not responding
// for that call only; the next call reads it again; the hung path is not read again while its read hangs.
TEST(DiskProbe, AHealthyPathBehindAHungOneIsReadAgain)
{
    DiskProbe probe(options());
    const int before = g_hungReads;
    const QHash<QString, int> first = ask(probe, {QStringLiteral("/hung/a"), QStringLiteral("/tmp")});
    EXPECT_EQ(first.value(QStringLiteral("/hung/a")), DiskProbe::kNotResponding);
    EXPECT_EQ(first.value(QStringLiteral("/tmp")), DiskProbe::kNotResponding) << "queued behind the hung read";
    EXPECT_EQ(probe.stuck(), 1);
    for (int i = 0; i < 3; ++i) {
        qint64 took = 0;
        const QHash<QString, int> again = ask(probe, {QStringLiteral("/tmp"), QStringLiteral("/hung/a")}, &took);
        EXPECT_EQ(again.value(QStringLiteral("/tmp")), 2) << "read again, call " << i;
        EXPECT_EQ(again.value(QStringLiteral("/hung/a")), DiskProbe::kNotResponding);
        EXPECT_LT(took, 250) << "the stuck path is not waited for";
    }
    EXPECT_EQ(g_hungReads - before, 1) << "a stuck path is not read twice";
}

// A stuck read gives its place back when it returns (re-review of 65311e0, MINOR 5): the path is read again by the next call.
TEST(DiskProbe, AStuckReadGivesItsPlaceBack)
{
    DiskProbe probe(options());
    const int before = g_hungReads;
    EXPECT_EQ(ask(probe, {QStringLiteral("/hung/b")}).value(QStringLiteral("/hung/b")), DiskProbe::kNotResponding);
    EXPECT_EQ(probe.stuck(), 1);
    ASSERT_TRUE(waitFor([&] { return probe.stuck() == 0; }, kHungMs + 1000)) << "the read returned";
    // Read again (and hung again): a second read.
    EXPECT_EQ(ask(probe, {QStringLiteral("/hung/b")}).value(QStringLiteral("/hung/b")), DiskProbe::kNotResponding);
    EXPECT_EQ(g_hungReads - before, 2);
    waitFor([&] { return probe.stuck() == 0; }, kHungMs + 1000);
}

// With kMaxStuck reads stuck, a new path is not responding at once, healthy or not: stuck reads cannot pile up threads.
TEST(DiskProbe, StuckReadsAreBounded)
{
    DiskProbe probe(options(200));
    int ended = 0;
    const auto connection = QObject::connect(&probe, &DiskProbe::answered, [&] { ++ended; });
    for (int i = 0; i < DiskProbe::kMaxStuck; ++i)
        probe.probe({QStringLiteral("/hung/bound-%1").arg(i)});
    ASSERT_TRUE(waitFor([&] { return ended == DiskProbe::kMaxStuck; }, 1000)) << "all at once, well before the reads return";
    QObject::disconnect(connection);
    EXPECT_EQ(probe.stuck(), DiskProbe::kMaxStuck);
    qint64 took = 0;
    EXPECT_EQ(ask(probe, {QStringLiteral("/tmp")}, &took).value(QStringLiteral("/tmp")), DiskProbe::kNotResponding);
    EXPECT_LT(took, 150);
    ASSERT_TRUE(waitFor([&] { return probe.stuck() == 0; }, kHungMs + 2000));
    EXPECT_EQ(ask(probe, {QStringLiteral("/tmp")}).value(QStringLiteral("/tmp")), 2) << "the bound is given back";
}

// The deadline counts from the last answer, and a call ends after totalMs at most (re-review of 65311e0, MINOR 3): a share
// that answers every 150 ms is waited for past the 300-ms quiet deadline, up to the 1-s total.
TEST(DiskProbe, ASlowShareIsWaitedForUpToTheTotal)
{
    DiskProbe probe(options(300, 1000));
    QStringList paths;
    for (int i = 0; i < 12; ++i)
        paths << QStringLiteral("/slow/%1").arg(i);
    qint64 took = 0;
    const QHash<QString, int> kinds = ask(probe, paths, &took);
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/0")), 2);
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/4")), 2) << "past the quiet deadline, still answering";
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/11")), DiskProbe::kNotResponding) << "past the total";
    EXPECT_GE(took, 950);
    EXPECT_LT(took, 1400);
    waitFor([&] { return probe.stuck() == 0; }, 1000);
}

// Files' sidebar (re-review of 65311e0, MAJOR 2): the standard folders are asked about off the GUI thread. The list comes
// at once; a folder that is not there leaves it; one that does not answer stays, unavailable (dimmed).
TEST(PlacesModelDisk, AHungStandardFolderIsListedUnavailable)
{
    const QString config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    ASSERT_FALSE(config.isEmpty());
    QDir().mkpath(config);
    QFile dirs(config + QStringLiteral("/user-dirs.dirs"));
    ASSERT_FALSE(dirs.exists()) << "the scratch home has none";
    ASSERT_TRUE(dirs.open(QIODevice::WriteOnly));
    dirs.write("XDG_DOCUMENTS_DIR=\"/hung/Documents\"\nXDG_PICTURES_DIR=\"$HOME/No Pictures\"\n");
    dirs.close();
    QElapsedTimer clock;
    clock.start();
    PlacesModel places(nullptr, options());
    EXPECT_LT(clock.elapsed(), 200) << "the GUI thread did not wait on the disk";
    const auto row = [&](const QString &name) {
        for (int r = 0; r < places.rowCount(); ++r)
            if (places.data(places.index(r), PlacesModel::NameRole).toString() == name)
                return r;
        return -1;
    };
    ASSERT_GE(row(QStringLiteral("Documents")), 0) << "listed at once";
    EXPECT_FALSE(places.data(places.index(row(QStringLiteral("Documents"))), PlacesModel::UnavailableRole).toBool());
    ASSERT_TRUE(waitFor([&] { return row(QStringLiteral("Pictures")) < 0; }, 2000)) << "a folder that is not there leaves";
    // Documents' own call ends at its deadline: listed, unavailable.
    EXPECT_TRUE(waitFor([&] {
        const int r = row(QStringLiteral("Documents"));
        return r >= 0 && places.data(places.index(r), PlacesModel::UnavailableRole).toBool();
    }, 1000)) << "a folder that does not answer stays, dimmed";
    EXPECT_GE(row(QStringLiteral("Home")), 0);
    EXPECT_FALSE(places.data(places.index(row(QStringLiteral("Home"))), PlacesModel::UnavailableRole).toBool());
    QFile::remove(dirs.fileName());
    waitFor([] { return false; }, kHungMs); // the hung read returns before the next test
}
