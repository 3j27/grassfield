// The image worker's decoding (ADR-0034 §1f): only the format given, every detection off, bounded sizes, bounded output.
#include "cliplogic.h"
#include "thumbnail.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QImage>
#include <QImageWriter>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>

#include <gtest/gtest.h>

#include <cerrno>

#include <signal.h>

namespace
{
void app()
{
    static int argc = 1;
    static char name[] = "clipboard-helper-unit-tests";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv); // image plugins are found through it
}

QByteArray encoded(int w, int h, const char *format)
{
    QImage image(w, h, QImage::Format_RGB32);
    image.fill(Qt::darkCyan);
    QByteArray out;
    QBuffer buffer(&out);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, format);
    writer.write(image);
    return out;
}

// A stand-in worker: a bash script given to ThumbnailJob in place of the helper's binary.
QString script(const QTemporaryDir &dir, const char *name, const QByteArray &body)
{
    const QString path = dir.path() + QLatin1Char('/') + QLatin1String(name);
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return {};
    f.write("#!/usr/bin/bash\n" + body);
    f.close();
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    return path;
}

struct JobResult {
    bool called = false;
    QByteArray png;
    qint64 ms = 0;
};

JobResult runJob(const QString &program, const QByteArray &image)
{
    JobResult r;
    QEventLoop loop;
    QElapsedTimer clock;
    clock.start();
    ThumbnailJob job(program, "png", 256, image, [&](const QByteArray &png) {
        r.called = true;
        r.png = png;
        r.ms = clock.elapsed();
        loop.quit();
    });
    QTimer::singleShot(10000, &loop, &QEventLoop::quit);
    job.start();
    if (!r.called)
        loop.exec();
    return r;
}
} // namespace

TEST(Thumbnail, DecodesAndScales)
{
    app();
    QByteArray error;
    QImage t = Thumbnail::decode(encoded(1000, 500, "png"), "png", 256, &error);
    ASSERT_FALSE(t.isNull()) << error.constData();
    EXPECT_EQ(t.width(), 256);
    EXPECT_EQ(t.height(), 128);
    t = Thumbnail::decode(encoded(100, 80, "jpeg"), "jpeg", 256, &error);
    ASSERT_FALSE(t.isNull()) << error.constData();
    EXPECT_EQ(t.size(), QSize(100, 80)) << "never enlarged";
    const QByteArray png = Thumbnail::encodePng(t);
    EXPECT_FALSE(png.isEmpty());
    EXPECT_LE(png.size(), ClipLogic::kThumbnailBytes);
}

TEST(Thumbnail, OnlyTheFormatGiven)
{
    app();
    QByteArray error;
    // A PNG offer whose bytes are something else never reaches that format's plugin.
    EXPECT_TRUE(Thumbnail::decode("%PDF-1.7\n1 0 obj\n", "png", 256, &error).isNull());
    EXPECT_TRUE(Thumbnail::decode("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>", "png", 256, &error).isNull());
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "jpeg"), "png", 256, &error).isNull()) << "JPEG bytes offered as PNG";
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "png"), "gif", 256, &error).isNull());
    EXPECT_EQ(error, QByteArray("format not allowed"));
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "png"), "svg", 256, &error).isNull());
}

TEST(Thumbnail, SizeLimits)
{
    app();
    QByteArray error;
    EXPECT_TRUE(Thumbnail::decode(encoded(ClipLogic::kMaxImageSide + 1, 2, "png"), "png", 256, &error).isNull());
    EXPECT_EQ(error, QByteArray("too large"));
    EXPECT_TRUE(Thumbnail::decode(QByteArray(), "png", 256, &error).isNull());
}

TEST(ThumbnailJob, AWorkerStillRunningAfterTwoSecondsIsKilled)
{
    app();
    QTemporaryDir dir;
    const QString sleep = QStandardPaths::findExecutable(QStringLiteral("sleep"));
    ASSERT_FALSE(sleep.isEmpty());
    // The worker leaves its pid as a directory name (RLIMIT_FSIZE 0 forbids writing a file, not making a directory), then
    // becomes `sleep 30` under the same pid.
    const QByteArray body = "mkdir " + QFile::encodeName(dir.path()) + "/alive.$$ || exit 9\nexec " + QFile::encodeName(sleep) + " 30\n";
    const JobResult r = runJob(script(dir, "slow-worker", body), "x");
    ASSERT_TRUE(r.called);
    EXPECT_TRUE(r.png.isEmpty()) << "a late worker gives nothing";
    EXPECT_GE(r.ms, Thumbnail::kDeadlineMs - 100);
    EXPECT_LT(r.ms, Thumbnail::kDeadlineMs + 3000);
    const QStringList marks = QDir(dir.path()).entryList({QStringLiteral("alive.*")}, QDir::Dirs);
    ASSERT_EQ(marks.size(), 1) << "the worker ran";
    const pid_t pid = pid_t(marks.first().section(QLatin1Char('.'), 1).toInt());
    ASSERT_GT(pid, 0);
    errno = 0;
    EXPECT_EQ(::kill(pid, 0), -1) << "the worker process is gone (killed and reaped), not left running";
    EXPECT_EQ(errno, ESRCH);
}

TEST(ThumbnailJob, TheWorkerGetsItsLimitsTheImageAndOnlyLcAll)
{
    app();
    QTemporaryDir dir;
    // Answers "ok" only when its arguments, rlimits, environment and stdin are the worker's; anything else is a failure.
    const QString program = script(dir, "probe-worker",
                                   QByteArray("[ \"$1 $2 $3\" = \"--thumbnail png 256\" ] || exit 2\n")
                                       + "[ \"$(ulimit -v)\" = " + QByteArray::number(Thumbnail::kAddressSpace / 1024) + " ] || exit 3\n"
                                       + "[ \"$(ulimit -t)\" = " + QByteArray::number(Thumbnail::kCpuSeconds) + " ] || exit 4\n"
                                       + "[ \"$(ulimit -f)\" = 0 ] || exit 5\n"
                                   "[ \"$LC_ALL\" = C ] || exit 6\n"
                                   "for n in $(compgen -e); do case $n in LC_ALL|PWD|OLDPWD|SHLVL|_) ;; *) exit 7 ;; esac; done\n"
                                   "IFS= read -r -d '' input\n"
                                   "[ \"$input\" = image-bytes ] || exit 8\n"
                                   "printf ok\n");
    const JobResult r = runJob(program, "image-bytes");
    ASSERT_TRUE(r.called);
    EXPECT_EQ(r.png, QByteArray("ok"));
}

TEST(ThumbnailJob, AWorkerThatCannotStartGivesNothing)
{
    app();
    const JobResult r = runJob(QStringLiteral("/nonexistent/grassfield-clipboard-helper"), "x");
    ASSERT_TRUE(r.called);
    EXPECT_TRUE(r.png.isEmpty());
}

TEST(ThumbnailJob, ADeletedJobReportsNothing)
{
    app();
    QTemporaryDir dir;
    const QString sleep = QStandardPaths::findExecutable(QStringLiteral("sleep"));
    ASSERT_FALSE(sleep.isEmpty());
    bool called = false;
    auto *job = new ThumbnailJob(script(dir, "slow-worker", "exec " + QFile::encodeName(sleep) + " 30\n"), "png", 256, "x",
                                 [&called](const QByteArray &) { called = true; });
    job->start();
    QElapsedTimer clock;
    clock.start();
    delete job; // the helper ending with a worker running (QUIT, stdin closed)
    EXPECT_FALSE(called);
    EXPECT_LT(clock.elapsed(), 2000) << "the worker is killed, not waited for";
}
