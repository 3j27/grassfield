// Backend (apps/settings/src/backend.h): the glue between the pages and their processes (counter-review of PR #6). A request
// gets its own answer unless it opts in to reuse a command still running (Storage's counts); an action that may wait for a
// password runs one per tag. Nothing real runs: PATH holds only a scratch folder of fake commands, each of which records its
// starts, so omarchy-language, wpctl or any other tool of the machine cannot be reached; no test talks to a bus.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QMap>
#include <QTemporaryDir>
#include <QThread>

#include <algorithm>

#include "backend.h"

namespace {

// One application object per process: tst_busjobs.cpp, in the same binary, may have made it first.
QCoreApplication &app()
{
    if (QCoreApplication *existing = QCoreApplication::instance())
        return *existing;
    static int argc = 1;
    static char name[] = "tst_backend";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv);
    return instance;
}

template<typename Predicate>
bool spinUntil(Predicate done, int ms = 5000)
{
    QElapsedTimer t;
    t.start();
    while (!done() && t.elapsed() < ms) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(2);
    }
    return done();
}

// What a Backend answered: finished signals per tag, pendingActionsChanged signals. Declared before the Backend, so it outlives it.
struct Answers {
    QMap<QString, int> finished;
    int pendingChanges = 0;

    void listen(Backend &backend)
    {
        QObject::connect(&backend, &Backend::finished, [this](const QString &tag, bool, const QString &) { ++finished[tag]; });
        QObject::connect(&backend, &Backend::pendingActionsChanged, [this] { ++pendingChanges; });
    }
};

} // namespace

// A real (not dev) session, whose PATH is a scratch folder of fake commands; both restored afterwards.
class BackendTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        app();
        ASSERT_TRUE(m_dir.isValid());
        m_path = qgetenv("PATH");
        m_hadDev = qEnvironmentVariableIsSet("GRASSFIELD_DEV");
        m_dev = qgetenv("GRASSFIELD_DEV");
        // Only the scratch folder: the machine's own tools are never found, whatever the Backend is asked to run.
        qputenv("PATH", QFile::encodeName(m_dir.path()));
        qunsetenv("GRASSFIELD_DEV"); // a dev session would suppress every action
        for (const char *tool : {"gf-fake-query", "omarchy-language", "wpctl"})
            writeTool(QString::fromLatin1(tool));
    }

    void TearDown() override
    {
        qputenv("PATH", m_path);
        if (m_hadDev)
            qputenv("GRASSFIELD_DEV", m_dev);
        else
            qunsetenv("GRASSFIELD_DEV");
    }

    // How many times the fake `tool` started.
    int runs(const QString &tool) const
    {
        QFile f(m_dir.filePath(tool + QStringLiteral(".runs")));
        return f.open(QIODevice::ReadOnly) ? f.readAll().count('\n') : 0;
    }

private:
    // A fake command: records its start, answers after a moment (long enough for a second request to find it running).
    void writeTool(const QString &tool)
    {
        QFile f(m_dir.filePath(tool));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\necho run >> '" + QFile::encodeName(m_dir.filePath(tool + QStringLiteral(".runs"))) + "'\n/usr/bin/sleep 0.3\necho done\n");
        f.close();
        ASSERT_TRUE(f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
    }

    QTemporaryDir m_dir;
    QByteArray m_path;
    QByteArray m_dev;
    bool m_hadDev = false;
};

// ---- queries: one answer per request ----

// The regression of 0a336de: WallpaperPage counts one finished per thumbnail request (thumbBusy, two at a time). A click on a
// tile asks again for a thumbnail still in flight (it updates Recents); when that second request got no answer of its own, the
// count stayed one too high, and after two such clicks no thumbnail loaded until the page was opened again.
TEST_F(BackendTest, EveryRequestOfAThumbnailGetsItsOwnAnswer)
{
    const QString tag = QStringLiteral("wp.thumb:/pictures/a.jpg");
    const QStringList argv{QStringLiteral("gf-fake-query"), QStringLiteral("thumb"), QStringLiteral("--"), QStringLiteral("/pictures/a.jpg")};
    int busy = 0; // WallpaperPage.thumbBusy: up on each request, down (not below 0) on each answer
    Answers seen;
    Backend backend;
    seen.listen(backend);
    QObject::connect(&backend, &Backend::finished, [&busy, tag](const QString &t, bool, const QString &) {
        if (t == tag)
            busy = std::max(0, busy - 1);
    });
    ++busy;
    backend.query(argv, tag, 20000);
    ++busy;
    backend.query(argv, tag, 20000); // the same picture again while its thumbnail is the one in flight
    EXPECT_TRUE(spinUntil([&] { return busy == 0; })) << "the page waits for " << busy << " answer(s) that never come";
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 2);
    EXPECT_EQ(busy, 0);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 2);
}

// Storage shown again while its counts run (du and pacman -Qi, up to two minutes each) opts in: the command still running under
// the same tag is not started again, and its one answer reaches the new page, which counts one answer per count.
TEST_F(BackendTest, ASharedQueryStillRunningIsReused)
{
    const QString tag = QStringLiteral("storage.du");
    const QStringList argv{QStringLiteral("gf-fake-query"), QStringLiteral("-s"), QStringLiteral("/home/u/Documents")};
    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.query(argv, tag, 5000, true);
    backend.query(argv, tag, 5000, true); // the page shown again
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 1);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 1);

    // Once it answered, the same query runs again; another command under a running tag is not that command: it runs too.
    backend.query(argv, tag, 5000, true);
    backend.query({QStringLiteral("gf-fake-query"), QStringLiteral("-s"), QStringLiteral("/home/u/Music")}, tag, 5000, true);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 3; }));
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 3);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 3);
}

// ---- actions: one per tag while it may wait for a password ----

// Language & Region shown again while Omarchy's prompt is up (omarchy-language may wait for pkexec) cannot start a second
// prompt: the waiting state is the Backend's (pendingActions), not the page's, which every visit creates anew.
TEST_F(BackendTest, AnActionThatMayAskForAPasswordIsRefusedWhileOneOfItsTagRuns)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("language.act");
    const QString what = QStringLiteral("language");
    ASSERT_TRUE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, tag));
    EXPECT_EQ(backend.pendingActions(), (QVariantMap{{tag, what}}));
    EXPECT_EQ(seen.pendingChanges, 1);

    // Refused, whatever it asks: nothing starts, no answer comes for it, the first one stays pending.
    EXPECT_FALSE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, tag));
    EXPECT_FALSE(backend.act(QStringLiteral("other"), {QStringLiteral("omarchy-language"), QStringLiteral("de")}, tag));
    EXPECT_EQ(backend.pendingActions(), (QVariantMap{{tag, what}}));
    EXPECT_EQ(seen.pendingChanges, 1);

    // It ends: the tag is free again, and its one answer came.
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(seen.pendingChanges, 2);
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 1);
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 1);

    // The next change of that tag runs.
    EXPECT_TRUE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("de")}, tag));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 2; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 2);
}

TEST_F(BackendTest, AnotherTagIsAnotherAction)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    EXPECT_TRUE(backend.act(QStringLiteral("language"), {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, QStringLiteral("language.act")));
    EXPECT_TRUE(backend.act(QStringLiteral("language"), {QStringLiteral("omarchy-language"), QStringLiteral("de")}, QStringLiteral("other.act")));
    EXPECT_EQ(backend.pendingActions().size(), 2);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("language.act")) == 1 && seen.finished.value(QStringLiteral("other.act")) == 1; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 2);
}

// An action that never asks for a password is not held back (the volume slider sends one wpctl per step) and is never pending.
TEST_F(BackendTest, AnActionWithoutAPasswordIsNotHeldBack)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("audio.act");
    EXPECT_TRUE(backend.act(QStringLiteral("volume"), {QStringLiteral("wpctl"), QStringLiteral("set-volume"), QStringLiteral("52"), QStringLiteral("0.4")}, tag));
    EXPECT_TRUE(backend.act(QStringLiteral("volume"), {QStringLiteral("wpctl"), QStringLiteral("set-volume"), QStringLiteral("52"), QStringLiteral("0.5")}, tag));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) == 2; }));
    EXPECT_EQ(seen.pendingChanges, 0);
    EXPECT_EQ(runs(QStringLiteral("wpctl")), 2);
}
