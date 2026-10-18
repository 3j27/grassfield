// Unit tests for the tag search runner (apps/files/src/tagsearch.{h,cpp}), gtest, run by scripts/dev/test.sh.
// Regression: disconnect() does not cancel calls already queued from the worker thread, so after a switch to another
// tag (or a reload) the batches and the done() of the superseded search used to land in the new results.
// Files are created under GRASSFIELD_TEST_TMP (a directory inside .dev/); the tests skip without it or without user
// extended attributes.
#include "tagsearch.h"
#include "taglogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QTemporaryDir>
#include <QThread>

#include <memory>
#include <sys/xattr.h>

#include <gtest/gtest.h>

namespace
{
QCoreApplication &app()
{
    static int argc = 1;
    static char name[] = "tst_tagsearch";
    static char *argv[] = {name, nullptr};
    static QCoreApplication application(argc, argv);
    return application;
}

std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/search-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

// A folder `name` in `root` holding `count` files tagged `tag`. False when the filesystem has no user attributes.
bool tagged(const QTemporaryDir &root, const QString &name, const QString &tag, int count)
{
    QDir().mkpath(root.filePath(name));
    for (int i = 0; i < count; ++i) {
        const QString path = root.filePath(name + QStringLiteral("/%1-%2").arg(name).arg(i));
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly))
            return false;
        f.close();
        const QByteArray value = tag.toUtf8();
        if (::lsetxattr(QFile::encodeName(path).constData(), "user.xdg.tags", value.constData(), size_t(value.size()), 0) != 0)
            return false;
    }
    return true;
}

struct Seen {
    QStringList paths;
    int done = 0;
    bool limited = false;
};

void connectTo(SearchRunner &runner, Seen *seen)
{
    QObject::connect(&runner, &SearchRunner::found, &runner, [seen](const QStringList &p) { seen->paths += p; });
    QObject::connect(&runner, &SearchRunner::done, &runner, [seen](bool limited, int) {
        ++seen->done;
        seen->limited = limited;
    });
}

// Runs the event loop until `until` holds or two seconds passed.
template<typename F>
bool spinUntil(F until)
{
    QElapsedTimer t;
    t.start();
    while (!until() && t.elapsed() < 2000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(2);
    }
    return until();
}
} // namespace

TEST(SearchRunner, FindsTheTaggedFilesAndReportsDoneOnce)
{
    app();
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    if (!tagged(*dir, QStringLiteral("a"), QStringLiteral("Red"), 3))
        GTEST_SKIP() << "no user extended attributes here";
    SearchRunner runner;
    Seen seen;
    connectTo(runner, &seen);
    runner.start(dir->path(), QStringLiteral("Red"), false);
    ASSERT_TRUE(spinUntil([&] { return seen.done > 0; }));
    EXPECT_EQ(seen.paths.size(), 3);
    EXPECT_EQ(seen.done, 1);
    EXPECT_FALSE(runner.running());
}

TEST(SearchRunner, BatchesOfASupersededSearchNeverArrive)
{
    app();
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    if (!tagged(*dir, QStringLiteral("one"), QStringLiteral("Red"), 40) || !tagged(*dir, QStringLiteral("two"), QStringLiteral("Blue"), 5))
        GTEST_SKIP() << "no user extended attributes here";
    SearchRunner runner;
    Seen seen;
    connectTo(runner, &seen);
    runner.start(dir->path(), QStringLiteral("Red"), false);
    // The first search finishes while the event loop is not running: its batch and done() are queued for `runner`.
    QThread::msleep(300);
    runner.start(dir->path(), QStringLiteral("Blue"), false);
    ASSERT_TRUE(spinUntil([&] { return seen.done > 0; }));
    // Let anything stale still in the queue arrive.
    QCoreApplication::processEvents();
    QThread::msleep(50);
    QCoreApplication::processEvents();
    EXPECT_EQ(seen.paths.size(), 5);
    for (const QString &p : std::as_const(seen.paths))
        EXPECT_TRUE(p.contains(QStringLiteral("/two/"))) << p.toStdString();
    EXPECT_EQ(seen.done, 1);
}

TEST(SearchRunner, StopDropsWhatIsQueued)
{
    app();
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    if (!tagged(*dir, QStringLiteral("one"), QStringLiteral("Red"), 40))
        GTEST_SKIP() << "no user extended attributes here";
    SearchRunner runner;
    Seen seen;
    connectTo(runner, &seen);
    runner.start(dir->path(), QStringLiteral("Red"), false);
    QThread::msleep(300);
    runner.stop();
    QCoreApplication::processEvents();
    QThread::msleep(50);
    QCoreApplication::processEvents();
    EXPECT_TRUE(seen.paths.isEmpty());
    EXPECT_EQ(seen.done, 0);
}
