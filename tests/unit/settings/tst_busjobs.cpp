// BusJobs (apps/settings/src/busjobs.h): the lifetime of the D-Bus jobs of the Settings window (GF-049 review: a job held a raw
// Backend pointer and ~Backend neither waited nor cancelled). Plain jobs, no bus: a caller that does nothing.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QPair>
#include <QProcess>
#include <QProcessEnvironment>
#include <QThread>

#include <atomic>
#include <memory>

#include "busjobs.h"

using namespace grassfield::settings;

namespace {

QCoreApplication &app()
{
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
// GF_BUSJOBS_CHILD, and the scenario runs from a static initializer, before gtest's main. 99 is what the child would leave with
// if the abandon path did not take it out: it is never reached.
namespace {
struct ChildMode {
    ChildMode()
    {
        const QByteArray mode = qgetenv("GF_BUSJOBS_CHILD");
        if (mode.isEmpty())
            return;
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
    env.insert(QStringLiteral("GF_BUSJOBS_CHILD"), QString::fromLatin1(mode));
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
