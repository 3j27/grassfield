// BusJobs (apps/settings/src/busjobs.h): the lifetime of the D-Bus jobs of the Settings window (GF-049 review: a job held a raw
// Backend pointer and ~Backend neither waited nor cancelled). Plain jobs, no bus: a caller that does nothing.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QPair>
#include <QProcess>
#include <QProcessEnvironment>
#include <QThread>

#include <unistd.h>

#include <atomic>
#include <memory>

#include "busjobs.h"

using namespace grassfield::settings;

namespace {

// One application object per process: tst_backend.cpp, in the same binary, may have made it first.
QCoreApplication &app()
{
    if (QCoreApplication *existing = QCoreApplication::instance())
        return *existing;
    static int argc = 1;
    static char name[] = "tst_busjobs";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv);
    return instance;
}

class NullCaller : public BusCaller
{
public:
    BusReply call(const QString &, const QString &, const QString &, const QString &, const QVariantList &, int) override { return {}; }
};

BusJobs::CallerFactory callers()
{
    return [] { return std::make_shared<NullCaller>(); };
}

template<typename Predicate>
bool spinUntil(Predicate done, int ms = 3000)
{
    QElapsedTimer t;
    t.start();
    while (!done() && t.elapsed() < ms) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(2);
    }
    return done();
}

// A job that blocks until `release` is set (at most 4 s, so that no test hangs).
BusJobs::Job blockedJob(const std::shared_ptr<std::atomic<bool>> &release)
{
    return [release](BusCaller &, QString *out) {
        for (int i = 0; i < 800 && !release->load(); ++i)
            QThread::msleep(5);
        *out = QStringLiteral("late");
        return QString();
    };
}

struct Seen {
    std::atomic<int> calls{0};
    QString reason;
    QString output;
    QThread *thread = nullptr;
};

} // namespace

class BusJobsTest : public ::testing::Test
{
protected:
    void SetUp() override { app(); }
};

TEST_F(BusJobsTest, ResultComesBackOnTheStartingThreadOnce)
{
    auto seen = std::make_shared<Seen>();
    BusJobs jobs(callers());
    jobs.start(
        [](BusCaller &, QString *out) {
            *out = QStringLiteral("{}");
            return QString();
        },
        [seen](const QString &reason, const QString &output) {
            ++seen->calls;
            seen->reason = reason;
            seen->output = output;
            seen->thread = QThread::currentThread();
        },
        5000);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }));
    EXPECT_EQ(seen->reason, QString());
    EXPECT_EQ(seen->output, QStringLiteral("{}"));
    EXPECT_EQ(seen->thread, QThread::currentThread());
    spinUntil([] { return false; }, 100);
    EXPECT_EQ(seen->calls.load(), 1);
}

// fprintd's enrolment statuses (ADR-0045 OC-0.7): what a job posts runs on the starting thread, in order, before its `done`;
// nothing posted runs after ~BusJobs.
TEST_F(BusJobsTest, PostedWorkRunsOnTheStartingThreadInOrderAndNeverAfterTheJobsGo)
{
    auto seen = std::make_shared<Seen>();
    auto order = std::make_shared<QStringList>();
    auto threads = std::make_shared<QList<QThread *>>();
    auto jobs = std::make_unique<BusJobs>(callers());
    const BusJobs::Post post = jobs->poster();
    jobs->start(
        [post, order, threads](BusCaller &, QString *) {
            for (const QString &s : {QStringLiteral("one"), QStringLiteral("two")})
                post([order, threads, s] {
                    order->append(s);
                    threads->append(QThread::currentThread());
                });
            return QString();
        },
        [seen, order](const QString &, const QString &) {
            order->append(QStringLiteral("done"));
            ++seen->calls;
        },
        5000);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }));
    EXPECT_EQ(*order, (QStringList{QStringLiteral("one"), QStringLiteral("two"), QStringLiteral("done")}));
    EXPECT_EQ(*threads, (QList<QThread *>{QThread::currentThread(), QThread::currentThread()}));
    // Posted once the jobs are gone: dropped.
    order->clear();
    jobs.reset();
    post([order] { order->append(QStringLiteral("late")); });
    spinUntil([] { return false; }, 100);
    EXPECT_TRUE(order->isEmpty());
}

TEST_F(BusJobsTest, AFailureCarriesItsReason)
{
    auto seen = std::make_shared<Seen>();
    BusJobs jobs(callers());
    jobs.start([](BusCaller &, QString *) { return QStringLiteral("nope"); }, [seen](const QString &reason, const QString &) {
        ++seen->calls;
        seen->reason = reason;
    }, 5000);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }));
    EXPECT_EQ(seen->reason, QStringLiteral("nope"));
}

TEST_F(BusJobsTest, NoCallerFailsTheJob)
{
    auto seen = std::make_shared<Seen>();
    BusJobs jobs([]() -> std::shared_ptr<BusCaller> { return nullptr; });
    jobs.start([](BusCaller &, QString *) { return QString(); }, [seen](const QString &reason, const QString &) {
        ++seen->calls;
        seen->reason = reason;
    }, 5000);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }));
    EXPECT_EQ(seen->reason, QStringLiteral("no connection to the system bus"));
}

TEST_F(BusJobsTest, ClosingMidJobRunsNoCallbackAndReturnsPromptly)
{
    // The case of the review: the window closes while a slow service has not answered. The job must not reach the destroyed
    // owner, and the destructor must not wait for the service.
    auto seen = std::make_shared<Seen>();
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto abandoned = std::make_shared<std::atomic<bool>>(false);
    QElapsedTimer t;
    {
        BusJobs jobs(callers(), 150, [abandoned] { *abandoned = true; });
        jobs.start(blockedJob(release), [seen](const QString &, const QString &) { ++seen->calls; }, 5000);
        QThread::msleep(30); // the job is running
        t.start();
    }
    EXPECT_LT(t.elapsed(), 1000) << "the destructor waited for the job";
    EXPECT_TRUE(abandoned->load()) << "a job still stuck is abandoned, not waited for";
    *release = true; // the service answers after the owner is gone
    spinUntil([] { return false; }, 150);
    EXPECT_EQ(seen->calls.load(), 0) << "a callback ran after the destruction";
}

TEST_F(BusJobsTest, ClosingAfterTheJobDroppedItsResultAndDoesNotAbandon)
{
    auto seen = std::make_shared<Seen>();
    auto abandoned = std::make_shared<std::atomic<bool>>(false);
    {
        BusJobs jobs(callers(), 500, [abandoned] { *abandoned = true; });
        jobs.start([](BusCaller &, QString *) { return QString(); }, [seen](const QString &, const QString &) { ++seen->calls; }, 5000);
        QThread::msleep(100); // done, its result posted but not delivered
    }
    spinUntil([] { return false; }, 100);
    EXPECT_FALSE(abandoned->load());
    EXPECT_EQ(seen->calls.load(), 0);
}

TEST_F(BusJobsTest, ClosingWaitsForAJobThatFinishesWithinTheBound)
{
    auto abandoned = std::make_shared<std::atomic<bool>>(false);
    {
        BusJobs jobs(callers(), 1000, [abandoned] { *abandoned = true; });
        jobs.start([](BusCaller &, QString *) {
            QThread::msleep(80);
            return QString();
        }, [](const QString &, const QString &) {}, 5000);
        QThread::msleep(20);
    }
    EXPECT_FALSE(abandoned->load());
}

TEST_F(BusJobsTest, ATimedOutJobAnswersOnceAndItsLateResultIsDropped)
{
    auto seen = std::make_shared<Seen>();
    auto release = std::make_shared<std::atomic<bool>>(false);
    BusJobs jobs(callers());
    jobs.start(blockedJob(release), [seen](const QString &reason, const QString &output) {
        ++seen->calls;
        seen->reason = reason;
        seen->output = output;
    }, 100);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }));
    EXPECT_EQ(seen->reason, QStringLiteral("timed out"));
    *release = true;
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen->calls.load(), 1) << "the late result answered a second time";
    EXPECT_EQ(seen->output, QString());
}

TEST_F(BusJobsTest, StuckJobsAreCappedNotPiledUp)
{
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto seen = std::make_shared<Seen>();
    BusJobs jobs(callers());
    for (int i = 0; i < BusJobs::kMaxInFlight; ++i)
        jobs.start(blockedJob(release), [](const QString &, const QString &) {}, 5000);
    jobs.start([](BusCaller &, QString *) { return QString(); }, [seen](const QString &reason, const QString &) {
        ++seen->calls;
        seen->reason = reason;
    }, 5000);
    ASSERT_TRUE(spinUntil([&] { return seen->calls.load() > 0; }, 1000));
    EXPECT_EQ(seen->reason, QStringLiteral("timed out"));
    *release = true;
    spinUntil([] { return false; }, 100);
}

// The default abandon path (every test above passes its own): the process leaves at once, with the application's own exit code
// (BusJobs::setExitCode, the result of exec()), not a 0 that hides a failure. gtest death tests are not used (they capture the
// child's stderr in /tmp, which a sandbox may not allow): this binary starts itself as the child, in the mode named by
// GF_BUSJOBS_CHILD ("<mode>@<parent pid>": a leaked value is ignored), and the scenario runs from a static initializer, before gtest's main. 99 is what the child would leave with
// if the abandon path did not take it out: it is never reached.
namespace {
struct ChildMode {
    ChildMode()
    {
        // "<mode>@<pid of the parent test>": a value that leaked into the environment of a shell does not name the parent of this
        // process, and must not make the test binary leave without running its tests.
        const QByteArray value = qgetenv("GF_BUSJOBS_CHILD");
        const int at = value.indexOf('@');
        if (at < 0 || value.mid(at + 1).toLongLong() != static_cast<qint64>(getppid()))
            return;
        const QByteArray mode = value.left(at);
        app();
        if (mode == "code7")
            BusJobs::setExitCode(7);
        auto release = std::make_shared<std::atomic<bool>>(false);
        {
            BusJobs jobs(callers(), 50); // the default abandon: flush and _Exit(exit code)
            jobs.start(blockedJob(release), [](const QString &, const QString &) {}, 5000);
            QThread::msleep(20);
        }
        std::_Exit(99);
    }
} childMode;

// {exit code, seconds}
QPair<int, qint64> runChild(const char *mode)
{
    QProcess child;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("GF_BUSJOBS_CHILD"), QString::fromLatin1(mode) + QLatin1Char('@') + QString::number(getpid()));
    child.setProcessEnvironment(env);
    QElapsedTimer t;
    t.start();
    child.start(QCoreApplication::applicationFilePath(), {});
    EXPECT_TRUE(child.waitForFinished(15000));
    EXPECT_EQ(child.exitStatus(), QProcess::NormalExit);
    return {child.exitCode(), t.elapsed()};
}
} // namespace

TEST_F(BusJobsTest, TheDefaultAbandonExitsWithTheApplicationsCode)
{
    const auto r = runChild("code7");
    EXPECT_EQ(r.first, 7) << "the abandon path must keep the exit code of the application";
    EXPECT_LT(r.second, 4000) << "the child waited for its stuck job";
}

TEST_F(BusJobsTest, TheDefaultAbandonExitsWithZeroWhenTheAppSucceeded)
{
    EXPECT_EQ(runChild("code0").first, 0);
}

// ---- InFlight (integrator review of PR #6): the waiting state lives in the Backend, one action per tag ----

TEST(InFlight, OneActionPerTagUntilItEnds)
{
    InFlight actions;
    EXPECT_TRUE(actions.begin(QStringLiteral("host.act"), QStringLiteral("computer name")));
    // The page shown again sends the same change while the polkit dialog is up: refused, the first one stays.
    EXPECT_FALSE(actions.begin(QStringLiteral("host.act"), QStringLiteral("computer name")));
    EXPECT_FALSE(actions.begin(QStringLiteral("host.act"), QStringLiteral("other")));
    // Another tag is another action.
    EXPECT_TRUE(actions.begin(QStringLiteral("time.act"), QStringLiteral("time zone")));
    EXPECT_EQ(actions.map(), (QVariantMap{{QStringLiteral("host.act"), QStringLiteral("computer name")}, {QStringLiteral("time.act"), QStringLiteral("time zone")}}));
    actions.end(QStringLiteral("host.act"));
    EXPECT_EQ(actions.map(), (QVariantMap{{QStringLiteral("time.act"), QStringLiteral("time zone")}}));
    EXPECT_TRUE(actions.begin(QStringLiteral("host.act"), QStringLiteral("computer name")));
    actions.end(QStringLiteral("unknown.act")); // nothing to end: no change
    EXPECT_EQ(actions.map().size(), 2);
}

TEST(InFlight, AQueryRunningUnderItsTagIsReused)
{
    InFlight queries;
    const QString du = QStringLiteral("du\x1f-s\x1f/home/u/Documents");
    EXPECT_FALSE(queries.runs(QStringLiteral("storage.du"), du));
    EXPECT_TRUE(queries.begin(QStringLiteral("storage.du"), du));
    // Storage shown again: the same command under the same tag runs already; it is not started again.
    EXPECT_TRUE(queries.runs(QStringLiteral("storage.du"), du));
    EXPECT_FALSE(queries.runs(QStringLiteral("storage.du"), QStringLiteral("du\x1f-s\x1f/elsewhere")));
    EXPECT_FALSE(queries.runs(QStringLiteral("storage.packages"), du));
    queries.end(QStringLiteral("storage.du"));
    EXPECT_FALSE(queries.runs(QStringLiteral("storage.du"), du));
}
