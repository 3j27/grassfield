// One Grassfield Store per user (apps/store/src/storeinstance.h; ADR-0037 SD35): the bus name, which keeps a dev or isolated
// run away from the owner's live Store; the cleaning of what a second launch hands over; and the hand-over itself on a private
// session bus (dbus-daemon --session, as tests/unit/settings/tst_settingsinstance.cpp): a launch takes the name, or hands
// its page over and leaves, also while the running Store is still starting; it runs only once the name has no owner left.
// No test touches the session's own bus.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDBusConnection>
#include <QElapsedTimer>
#include <QMutex>
#include <QProcess>
#include <QThread>

#include <chrono>
#include <csignal>
#include <cstdio>
#include <thread>

#include <unistd.h>

#include "storeinstance.h"

using grassfield::store::claimOrHandOver;
using grassfield::store::Launch;
using grassfield::store::StoreInstance;

namespace {

// One application object per process: the other suites of the binary may have made it first.
QCoreApplication &app()
{
    if (QCoreApplication *existing = QCoreApplication::instance())
        return *existing;
    static int argc = 1;
    static char name[] = "tst_storeinstance";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv);
    return instance;
}

// The run-mode variables a case sets, put back as they were.
class RunModeGuard
{
public:
    RunModeGuard()
    {
        for (const char *n : {"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_STATE_HOME"})
            m_saved.append({n, qEnvironmentVariableIsSet(n), qgetenv(n)});
        qunsetenv("GRASSFIELD_DEV");
        qunsetenv("GRASSFIELD_SESSION");
        qunsetenv("GRASSFIELD_STATE_HOME");
    }
    ~RunModeGuard()
    {
        for (const Saved &s : std::as_const(m_saved)) {
            if (s.set)
                qputenv(s.name, s.value);
            else
                qunsetenv(s.name);
        }
    }

private:
    struct Saved {
        const char *name;
        bool set;
        QByteArray value;
    };
    QList<Saved> m_saved;
};

// A private session bus for one case, stopped with it; empty where there is no dbus-daemon.
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

// What a StoreInstance was asked for, from any thread.
struct Requests {
    QMutex mutex;
    QStringList seen;

    void listen(StoreInstance *instance)
    {
        QObject::connect(instance, &StoreInstance::openRequested, instance, [this](const QString &page, const QString &token) {
            QMutexLocker lock(&mutex);
            seen << QStringLiteral("open %1 %2").arg(page, token);
        }, Qt::DirectConnection);
    }
    QStringList list()
    {
        QMutexLocker lock(&mutex);
        return seen;
    }
};

// Owner mode (ALaunchWhoseOwnerDiesWhileAskedRuns): run with GF_STORE_TEST_OWNER set to a private bus's address, this binary
// is a Store that took the name and never answers (its thread sleeps), until it is killed. Before main: no test of the binary
// runs in that process.
const bool ownerMode = [] {
    const QByteArray address = qgetenv("GF_STORE_TEST_OWNER");
    if (address.isEmpty())
        return false;
    static int argc = 1;
    static char name[] = "tst_storeinstance-owner";
    static char *argv[] = {name, nullptr};
    QCoreApplication owner(argc, argv);
    QDBusConnection bus = QDBusConnection::connectToBus(QString::fromUtf8(address), QStringLiteral("owner"));
    // The object lives on this thread, which never runs its event loop: a call reaches it and is never answered.
    static StoreInstance instance;
    bus.registerObject(StoreInstance::objectPath(), &instance, QDBusConnection::ExportScriptableSlots);
    std::printf(bus.registerService(StoreInstance::serviceName()) ? "owned\n" : "refused\n");
    std::fflush(stdout);
    std::this_thread::sleep_for(std::chrono::seconds(30));
    _exit(0);
}();

void release(QDBusConnection &bus)
{
    bus.unregisterService(StoreInstance::serviceName());
    bus.unregisterObject(StoreInstance::objectPath());
}

} // namespace

// The session's Store is org.grassfield.Store; a run with its own state directory (a dev session, an isolated test run) adds
// ".Dev" in dev and a digest of that directory, so that it never hands a page to the owner's live Store, nor to another run's.
TEST(StoreInstance, TheNameKeepsADevOrIsolatedRunApart)
{
    RunModeGuard guard;
    EXPECT_EQ(StoreInstance::serviceName(), QStringLiteral("org.grassfield.Store"));

    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(StoreInstance::serviceName(), QStringLiteral("org.grassfield.Store.Dev"));

    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/state");
    const QString devRun = StoreInstance::serviceName();
    EXPECT_TRUE(devRun.startsWith(QStringLiteral("org.grassfield.Store.Dev.s"))) << qPrintable(devRun);
    EXPECT_EQ(devRun.size(), QStringLiteral("org.grassfield.Store.Dev.s").size() + 16);
    EXPECT_EQ(StoreInstance::serviceName(), devRun); // stable for one directory

    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/isolated/visual/grassfield-state");
    EXPECT_NE(StoreInstance::serviceName(), devRun); // another run's directory, another name

    // An isolated run of a real session (GRASSFIELD_DEV=0) is not the owner's Store either.
    qunsetenv("GRASSFIELD_DEV");
    const QString isolated = StoreInstance::serviceName();
    EXPECT_TRUE(isolated.startsWith(QStringLiteral("org.grassfield.Store.s"))) << qPrintable(isolated);
    // A GRASSFIELD_DEV=1 leaked into the packaged session (GRASSFIELD_SESSION=1) is not a dev session (ADR-0019).
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("GRASSFIELD_DEV", "1");
    qputenv("GRASSFIELD_SESSION", "1");
    EXPECT_EQ(StoreInstance::serviceName(), QStringLiteral("org.grassfield.Store"));

    // Every name is a valid bus name: elements of letters, digits and "_", none starting with a digit.
    qputenv("GRASSFIELD_STATE_HOME", "/tmp/0");
    for (const QString &element : StoreInstance::serviceName().split(QLatin1Char('.')))
        EXPECT_FALSE(element.isEmpty() || element.front().isDigit()) << qPrintable(StoreInstance::serviceName());
}

// What a second launch hands over is cleaned before it reaches the window: a printable page of 512 characters at most (its
// form is the window's to check), a printable token of 256 at most without spaces, else nothing.
TEST(StoreInstance, WhatALaunchHandsOverIsCleaned)
{
    EXPECT_EQ(StoreInstance::cleanPage(QStringLiteral("type:image/png")), QStringLiteral("type:image/png"));
    EXPECT_EQ(StoreInstance::cleanPage(QStringLiteral("updates")), QStringLiteral("updates"));
    EXPECT_EQ(StoreInstance::cleanPage(QStringLiteral("app:org.example Draw")), QStringLiteral("app:org.example Draw"));
    EXPECT_EQ(StoreInstance::cleanPage(QStringLiteral("updates\n")), QString());
    EXPECT_EQ(StoreInstance::cleanPage(QStringLiteral("a\x7f")), QString());
    EXPECT_EQ(StoreInstance::cleanPage(QString(512, QLatin1Char('a'))), QString(512, QLatin1Char('a')));
    EXPECT_EQ(StoreInstance::cleanPage(QString(513, QLatin1Char('a'))), QString());
    EXPECT_EQ(StoreInstance::cleanToken(QStringLiteral("abc_123-XYZ")), QStringLiteral("abc_123-XYZ"));
    EXPECT_EQ(StoreInstance::cleanToken(QStringLiteral("a b")), QString());
    EXPECT_EQ(StoreInstance::cleanToken(QStringLiteral("a\nb")), QString());
    EXPECT_EQ(StoreInstance::cleanToken(QStringLiteral("a\x7f")), QString());
    EXPECT_EQ(StoreInstance::cleanToken(QString(256, QLatin1Char('a'))), QString(256, QLatin1Char('a')));
    EXPECT_EQ(StoreInstance::cleanToken(QString(257, QLatin1Char('a'))), QString());

    StoreInstance instance;
    Requests requests;
    requests.listen(&instance);
    instance.Open(QStringLiteral("type:text/plain"), QStringLiteral("tok"));
    instance.Open(QStringLiteral("updates\t"), QStringLiteral("a b"));
    EXPECT_EQ(requests.list(), (QStringList{QStringLiteral("open type:text/plain tok"), QStringLiteral("open  ")}));
}

// A launch takes the name, or hands its page over and leaves, also while the running Store is still starting (it answers from
// its event loop, once its window exists); it runs only once the name has no owner left.
TEST(StoreInstance, ALaunchTakesTheNameOrHandsItsPageOverAndLeaves)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QDBusConnection first = QDBusConnection::connectToBus(pb.address, QStringLiteral("store-first"));
    QDBusConnection second = QDBusConnection::connectToBus(pb.address, QStringLiteral("store-second"));
    ASSERT_TRUE(first.isConnected() && second.isConnected());

    StoreInstance a, b;
    EXPECT_EQ(claimOrHandOver(first, &a, QString(), QStringLiteral("token-1"), 1000), Launch::Run);
    // The running Store is still starting (its thread does not run its event loop): the launch leaves anyway, its page queued
    // for that Store, and never opens a second one.
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("updates"), QString(), 300), Launch::Leave);

    // The running Store answers: the pages reach it, and each launch leaves.
    release(first);
    QThread owner;
    owner.start();
    auto *c = new StoreInstance;
    c->moveToThread(&owner);
    Requests requests;
    requests.listen(c);
    EXPECT_EQ(claimOrHandOver(first, c, QString(), QString(), 1000), Launch::Run);
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("type:image/png"), QStringLiteral("token-2"), 3000), Launch::Leave);
    EXPECT_EQ(claimOrHandOver(second, &b, QString(), QStringLiteral("token-3"), 3000), Launch::Leave);
    EXPECT_EQ(requests.list(), (QStringList{QStringLiteral("open type:image/png token-2"), QStringLiteral("open  token-3")}));

    // The running Store quits: the name has no owner left, and the next launch takes it and runs.
    release(first);
    owner.quit();
    owner.wait();
    delete c;
    EXPECT_EQ(claimOrHandOver(second, &b, QString(), QString(), 1000), Launch::Run);
    release(second);
}

// The running Store dies while a launch waits on it (the bus answers NoReply, not "no owner"): the name has no owner left, so
// the launch takes it and runs. The owner is this test binary run again (ownerMode, above): it takes the name, never answers,
// and is killed 800 ms into the call.
TEST(StoreInstance, ALaunchWhoseOwnerDiesWhileAskedRuns)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QProcess owner;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("GF_STORE_TEST_OWNER"), pb.address);
    owner.setProcessEnvironment(env);
    owner.start(QCoreApplication::applicationFilePath(), {});
    ASSERT_TRUE(owner.waitForReadyRead(5000));
    ASSERT_EQ(owner.readLine().trimmed(), QByteArray("owned"));
    const qint64 pid = owner.processId();
    std::thread killer([pid] {
        std::this_thread::sleep_for(std::chrono::milliseconds(800));
        ::kill(static_cast<pid_t>(pid), SIGKILL);
    });
    QDBusConnection launch = QDBusConnection::connectToBus(pb.address, QStringLiteral("store-launch"));
    ASSERT_TRUE(launch.isConnected());
    StoreInstance b;
    QElapsedTimer t;
    t.start();
    EXPECT_EQ(claimOrHandOver(launch, &b, QStringLiteral("updates"), QString(), 10000), Launch::Run);
    EXPECT_LT(t.elapsed(), 5000); // at the owner's death, not at the end of the wait
    killer.join();
    owner.waitForFinished(3000);
    release(launch);
}

// A dev run and the owner's Store on one bus (a dev session shares the owner's): the dev launch takes its own name and runs;
// it never hands its page to the owner's Store.
TEST(StoreInstance, ADevRunNeverReachesTheOwnersStore)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QDBusConnection owners = QDBusConnection::connectToBus(pb.address, QStringLiteral("store-owner"));
    QDBusConnection devs = QDBusConnection::connectToBus(pb.address, QStringLiteral("store-dev"));
    ASSERT_TRUE(owners.isConnected() && devs.isConnected());

    StoreInstance owner, dev;
    Requests requests;
    requests.listen(&owner);
    EXPECT_EQ(claimOrHandOver(owners, &owner, QString(), QString(), 1000), Launch::Run);
    const QString ownersName = StoreInstance::serviceName();
    qputenv("GRASSFIELD_DEV", "1");
    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/state");
    EXPECT_EQ(claimOrHandOver(devs, &dev, QStringLiteral("updates"), QString(), 1000), Launch::Run);
    EXPECT_NE(StoreInstance::serviceName(), ownersName);
    QCoreApplication::processEvents();
    EXPECT_TRUE(requests.list().isEmpty());
    release(devs);
    qunsetenv("GRASSFIELD_DEV");
    qunsetenv("GRASSFIELD_STATE_HOME");
    release(owners);
}
