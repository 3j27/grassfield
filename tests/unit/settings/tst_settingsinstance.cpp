// One Settings per user (apps/settings/src/settingsinstance.h; ADR-0040 step 1b, the reviews of ce69dc6 and c6cf328): the bus
// name, which keeps a dev or isolated run away from the owner's live Settings; the cleaning of what a second launch hands
// over; and the hand-over itself on a private session bus (dbus-daemon --session, as tests/unit/activity/window/
// tst_activityapp.cpp): a launch takes the name, or hands its request over and leaves, also while the running Settings is
// still starting; it runs only once the name has no owner left. No test touches the session's own bus.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDBusConnection>
#include <QMutex>
#include <QProcess>
#include <QElapsedTimer>
#include <QThread>

#include <chrono>
#include <csignal>
#include <cstdio>
#include <thread>

#include <unistd.h>

#include "settingsinstance.h"

using grassfield::settings::claimOrHandOver;
using grassfield::settings::Launch;
using grassfield::settings::SettingsInstance;

namespace {

// One application object per process: the other suites of the binary may have made it first.
QCoreApplication &app()
{
    if (QCoreApplication *existing = QCoreApplication::instance())
        return *existing;
    static int argc = 1;
    static char name[] = "tst_settingsinstance";
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

// What a SettingsInstance was asked for, from any thread.
struct Requests {
    QMutex mutex;
    QStringList seen;

    void listen(SettingsInstance *instance)
    {
        QObject::connect(instance, &SettingsInstance::settingsRequested, instance, [this](const QString &section, const QString &token) {
            QMutexLocker lock(&mutex);
            seen << QStringLiteral("open %1 %2").arg(section, token);
        }, Qt::DirectConnection);
        QObject::connect(instance, &SettingsInstance::aboutRequested, instance, [this](const QString &token) {
            QMutexLocker lock(&mutex);
            seen << QStringLiteral("about %1").arg(token);
        }, Qt::DirectConnection);
    }
    QStringList list()
    {
        QMutexLocker lock(&mutex);
        return seen;
    }
};

// Owner mode (ALaunchWhoseOwnerDiesWhileAskedRuns): run with GF_SETTINGS_TEST_OWNER set to a private bus's address, this
// binary is a Settings that took the name and never answers (its thread sleeps), until it is killed. Before main: no test
// of the binary runs in that process.
const bool ownerMode = [] {
    const QByteArray address = qgetenv("GF_SETTINGS_TEST_OWNER");
    if (address.isEmpty())
        return false;
    static int argc = 1;
    static char name[] = "tst_settingsinstance-owner";
    static char *argv[] = {name, nullptr};
    QCoreApplication owner(argc, argv);
    QDBusConnection bus = QDBusConnection::connectToBus(QString::fromUtf8(address), QStringLiteral("owner"));
    // The object lives on this thread, which never runs its event loop: a call reaches it and is never answered.
    static SettingsInstance instance;
    bus.registerObject(SettingsInstance::objectPath(), &instance, QDBusConnection::ExportScriptableSlots);
    std::printf(bus.registerService(SettingsInstance::serviceName()) ? "owned\n" : "refused\n");
    std::fflush(stdout);
    std::this_thread::sleep_for(std::chrono::seconds(30));
    _exit(0);
}();

void release(QDBusConnection &bus)
{
    bus.unregisterService(SettingsInstance::serviceName());
    bus.unregisterObject(SettingsInstance::objectPath());
}

} // namespace

// The session's Settings is org.grassfield.Settings; a run with its own state directory (a dev session, an isolated test run)
// adds ".Dev" in dev and a digest of that directory, so that it never hands a request to the owner's live Settings, nor to
// another run's (the re-review of c6cf328: nothing held that suffix).
TEST(SettingsInstance, TheNameKeepsADevOrIsolatedRunApart)
{
    RunModeGuard guard;
    EXPECT_EQ(SettingsInstance::serviceName(), QStringLiteral("org.grassfield.Settings"));

    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(SettingsInstance::serviceName(), QStringLiteral("org.grassfield.Settings.Dev"));

    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/state");
    const QString devRun = SettingsInstance::serviceName();
    EXPECT_TRUE(devRun.startsWith(QStringLiteral("org.grassfield.Settings.Dev.s"))) << qPrintable(devRun);
    EXPECT_EQ(devRun.size(), QStringLiteral("org.grassfield.Settings.Dev.s").size() + 16);
    EXPECT_EQ(SettingsInstance::serviceName(), devRun); // stable for one directory

    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/isolated/visual/grassfield-state");
    EXPECT_NE(SettingsInstance::serviceName(), devRun); // another run's directory, another name

    // An isolated run of a real session (GRASSFIELD_DEV=0) is not the owner's Settings either.
    qunsetenv("GRASSFIELD_DEV");
    const QString isolated = SettingsInstance::serviceName();
    EXPECT_TRUE(isolated.startsWith(QStringLiteral("org.grassfield.Settings.s"))) << qPrintable(isolated);
    // A GRASSFIELD_DEV=1 leaked into the packaged session (GRASSFIELD_SESSION=1) is not a dev session (ADR-0019).
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("GRASSFIELD_DEV", "1");
    qputenv("GRASSFIELD_SESSION", "1");
    EXPECT_EQ(SettingsInstance::serviceName(), QStringLiteral("org.grassfield.Settings"));

    // Every name is a valid bus name: elements of letters, digits and "_", none starting with a digit.
    qputenv("GRASSFIELD_STATE_HOME", "/tmp/0");
    for (const QString &element : SettingsInstance::serviceName().split(QLatin1Char('.')))
        EXPECT_FALSE(element.isEmpty() || element.front().isDigit()) << qPrintable(SettingsInstance::serviceName());
}

// What a second launch hands over is cleaned before it reaches a window: a sidebar id or nothing, a printable token or none.
TEST(SettingsInstance, WhatALaunchHandsOverIsCleaned)
{
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("wifi")), QStringLiteral("wifi"));
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("privacy-location")), QStringLiteral("privacy-location"));
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("software-update")), QStringLiteral("software-update"));
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("Bad Section!")), QString());
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("../wifi")), QString());
    EXPECT_EQ(SettingsInstance::cleanSection(QStringLiteral("1wifi")), QString());
    EXPECT_EQ(SettingsInstance::cleanSection(QString(41, QLatin1Char('a'))), QString());
    EXPECT_EQ(SettingsInstance::cleanToken(QStringLiteral("abc_123-XYZ")), QStringLiteral("abc_123-XYZ"));
    EXPECT_EQ(SettingsInstance::cleanToken(QStringLiteral("a b")), QString());
    EXPECT_EQ(SettingsInstance::cleanToken(QStringLiteral("a\nb")), QString());
    EXPECT_EQ(SettingsInstance::cleanToken(QString(257, QLatin1Char('a'))), QString());

    SettingsInstance instance;
    Requests requests;
    requests.listen(&instance);
    instance.Open(QStringLiteral("Bad Section!"), QStringLiteral("a b"));
    instance.About(QStringLiteral("tok"));
    instance.openSettings(QStringLiteral("about"));
    EXPECT_EQ(requests.list(), (QStringList{QStringLiteral("open  "), QStringLiteral("about tok"), QStringLiteral("open about ")}));
}

// A launch takes the name, or hands its request over and leaves, also while the running Settings is still starting (it answers
// from its event loop, once its windows exist; the re-review of c6cf328: a launch that gave up after 2 s opened a second
// Settings); it runs only once the name has no owner left.
TEST(SettingsInstance, ALaunchTakesTheNameOrHandsItsRequestOverAndLeaves)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QDBusConnection first = QDBusConnection::connectToBus(pb.address, QStringLiteral("settings-first"));
    QDBusConnection second = QDBusConnection::connectToBus(pb.address, QStringLiteral("settings-second"));
    ASSERT_TRUE(first.isConnected() && second.isConnected());

    SettingsInstance a, b;
    const QVariantList wifi{QStringLiteral("wifi"), QStringLiteral("token-1")};
    EXPECT_EQ(claimOrHandOver(first, &a, QStringLiteral("Open"), wifi, 1000), Launch::Run);
    // The running Settings is still starting (its thread does not run its event loop): the launch leaves anyway, its request
    // queued for that Settings, and never opens a second one.
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("Open"), wifi, 300), Launch::Leave);

    // The running Settings answers: the requests reach it, and each launch leaves.
    release(first);
    QThread owner;
    owner.start();
    auto *c = new SettingsInstance;
    c->moveToThread(&owner);
    Requests requests;
    requests.listen(c);
    EXPECT_EQ(claimOrHandOver(first, c, QStringLiteral("Open"), QVariantList{QString(), QString()}, 1000), Launch::Run);
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("Open"), QVariantList{QStringLiteral("sound"), QStringLiteral("token-2")}, 3000),
              Launch::Leave);
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("About"), QVariantList{QStringLiteral("token-3")}, 3000), Launch::Leave);
    EXPECT_EQ(requests.list(), (QStringList{QStringLiteral("open sound token-2"), QStringLiteral("about token-3")}));

    // The running Settings quits: the name has no owner left, and the next launch takes it and runs.
    release(first);
    owner.quit();
    owner.wait();
    delete c;
    EXPECT_EQ(claimOrHandOver(second, &b, QStringLiteral("About"), QVariantList{QString()}, 1000), Launch::Run);
    release(second);
}

// The running Settings dies while a launch waits on it (the re-review of 85c2c10: the bus answers NoReply, not "no owner",
// and that click was lost): the name has no owner left, so the launch takes it and runs. The owner is this test binary run
// again (ownerMode, above): it takes the name, never answers, and is killed 800 ms into the call.
TEST(SettingsInstance, ALaunchWhoseOwnerDiesWhileAskedRuns)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QProcess owner;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("GF_SETTINGS_TEST_OWNER"), pb.address);
    owner.setProcessEnvironment(env);
    owner.start(QCoreApplication::applicationFilePath(), {});
    ASSERT_TRUE(owner.waitForReadyRead(5000));
    ASSERT_EQ(owner.readLine().trimmed(), QByteArray("owned"));
    const qint64 pid = owner.processId();
    std::thread killer([pid] {
        std::this_thread::sleep_for(std::chrono::milliseconds(800));
        ::kill(static_cast<pid_t>(pid), SIGKILL);
    });
    QDBusConnection launch = QDBusConnection::connectToBus(pb.address, QStringLiteral("settings-launch"));
    ASSERT_TRUE(launch.isConnected());
    SettingsInstance b;
    QElapsedTimer t;
    t.start();
    EXPECT_EQ(claimOrHandOver(launch, &b, QStringLiteral("About"), QVariantList{QString()}, 10000), Launch::Run);
    EXPECT_LT(t.elapsed(), 5000); // at the owner's death, not at the end of the wait
    killer.join();
    owner.waitForFinished(3000);
    release(launch);
}

// A dev run and the owner's Settings on one bus (a dev session shares the owner's): the dev launch takes its own name and
// runs; it never hands its request to the owner's Settings.
TEST(SettingsInstance, ADevRunNeverReachesTheOwnersSettings)
{
    app();
    RunModeGuard guard;
    PrivateBus pb;
    if (pb.address.isEmpty())
        GTEST_SKIP() << "no dbus-daemon here";
    QDBusConnection owners = QDBusConnection::connectToBus(pb.address, QStringLiteral("settings-owner"));
    QDBusConnection devs = QDBusConnection::connectToBus(pb.address, QStringLiteral("settings-dev"));
    ASSERT_TRUE(owners.isConnected() && devs.isConnected());

    SettingsInstance owner, dev;
    Requests requests;
    requests.listen(&owner);
    EXPECT_EQ(claimOrHandOver(owners, &owner, QStringLiteral("Open"), QVariantList{QString(), QString()}, 1000), Launch::Run);
    const QString ownersName = SettingsInstance::serviceName();
    qputenv("GRASSFIELD_DEV", "1");
    qputenv("GRASSFIELD_STATE_HOME", "/home/u/grassfield/.dev/state");
    EXPECT_EQ(claimOrHandOver(devs, &dev, QStringLiteral("About"), QVariantList{QString()}, 1000), Launch::Run);
    EXPECT_NE(SettingsInstance::serviceName(), ownersName);
    QCoreApplication::processEvents();
    EXPECT_TRUE(requests.list().isEmpty());
    release(devs);
    qunsetenv("GRASSFIELD_DEV");
    qunsetenv("GRASSFIELD_STATE_HOME");
    release(owners);
}
