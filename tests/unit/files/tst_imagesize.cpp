// Unit tests for apps/files/src/imagesize.{h,cpp} (gtest): the preview pane's Dimensions never block the GUI thread
// (docs/specs/files.md "Preview pane"): a FIFO or a link to /dev/zero named like a picture is never opened, a huge file is
// read up to the budget only (a header that never ends included), a path on a network or FUSE mount is never looked at, a
// link swapped in after the check is never followed, and the Reader answers later on the caller's thread. Built and run by
// scripts/dev/test.sh. The files are made only under GRASSFIELD_TEST_TMP, a directory inside the repository's .dev/ (set by
// scripts/dev/test.sh); the tests skip without it.
#include "imagerotate.h"
#include "imagesize.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QImage>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>

#include <cerrno>
#include <cstdio>
#include <future>
#include <memory>
#include <thread>

#include <fcntl.h>
#include <linux/openat2.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <gtest/gtest.h>

namespace
{
std::unique_ptr<QTemporaryDir> sandbox()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/")))
        return nullptr;
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/imagesize-XXXXXX"));
    return dir->isValid() ? std::move(dir) : nullptr;
}

QCoreApplication &app()
{
    static int argc = 1;
    static char name[] = "tst_imagesize";
    static char *argv[] = {name, nullptr};
    if (!QCoreApplication::instance())
        new QCoreApplication(argc, argv);
    return *QCoreApplication::instance();
}

QByteArray encoded(const QImage &image, const char *format)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, format);
    return bytes;
}

bool write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(bytes) == bytes.size();
}

// Runs `f` on a thread of its own: whether it returned within `ms`. A call that hangs (the old reader on a FIFO) is
// left behind on its detached thread and fails the test instead of hanging the run.
template<typename F>
bool returnsWithin(int ms, F f)
{
    auto task = std::make_shared<std::packaged_task<void()>>(f);
    std::future<void> done = task->get_future();
    std::thread([task] { (*task)(); }).detach();
    return done.wait_for(std::chrono::milliseconds(ms)) == std::future_status::ready;
}

// A mount table where `point` is a filesystem of `type` on a local root.
FolderStyleStore::Mounts mountsWith(const QString &point, const QString &type)
{
    const QByteArray info = "22 1 0:21 / / rw - btrfs /dev/root rw\n"
                            "40 22 0:40 / " + QFile::encodeName(point) + " rw - " + type.toUtf8() + " server:/share rw\n";
    return FolderStyleStore::Mounts::parse(info, QByteArray());
}

// The special files named like pictures, in `dir`: a FIFO (no writer) and a link to /dev/zero.
struct Specials {
    QString fifo;
    QString zero;
};
Specials makeSpecials(const QString &dir)
{
    Specials s{dir + QStringLiteral("/pipe.png"), dir + QStringLiteral("/zero.png")};
    EXPECT_EQ(::mkfifo(QFile::encodeName(s.fifo).constData(), 0600), 0);
    EXPECT_TRUE(QFile::link(QStringLiteral("/dev/zero"), s.zero));
    return s;
}
} // namespace

TEST(ImageSize, SpecialFilesAreRefusedWithoutBeingOpened)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const Specials s = makeSpecials(dir->path());
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    EXPECT_EQ(ImageSize::check(s.fifo, mounts), ImageSize::Refusal::NotRegular);
    // /dev is devtmpfs here (a pseudo filesystem: not even looked at); on a table where it is a disk, the device itself is refused.
    EXPECT_NE(ImageSize::check(s.zero, mounts), ImageSize::Refusal::None);
    EXPECT_EQ(ImageSize::check(s.zero, mountsWith(QStringLiteral("/srv/unused"), QStringLiteral("nfs4"))), ImageSize::Refusal::NotRegular);
    EXPECT_EQ(ImageSize::check(dir->path(), mounts), ImageSize::Refusal::NotRegular) << "a folder";
    EXPECT_EQ(ImageSize::check(dir->path() + QStringLiteral("/missing.png"), mounts), ImageSize::Refusal::Unreadable);
    EXPECT_EQ(ImageSize::check(QStringLiteral("relative.png"), mounts), ImageSize::Refusal::Unreadable);
    QSize fifo(1, 1), zero(1, 1);
    EXPECT_TRUE(returnsWithin(2000, [&] { fifo = ImageSize::read(s.fifo, mounts); })) << "a FIFO named pipe.png blocked the read";
    EXPECT_TRUE(returnsWithin(2000, [&] { zero = ImageSize::read(s.zero, mounts); })) << "a link to /dev/zero blocked the read";
    EXPECT_FALSE(fifo.isValid());
    EXPECT_FALSE(zero.isValid());
}

TEST(ImageSize, PicturesAreReadByTheirContent)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    QImage image(40, 10, QImage::Format_RGB32);
    image.fill(Qt::red);
    const QString png = dir->path() + QStringLiteral("/shot.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    ASSERT_EQ(ImageSize::check(png, mounts), ImageSize::Refusal::None);
    EXPECT_EQ(ImageSize::read(png, mounts), QSize(40, 10));
    // A JPEG named .png: the content decides.
    const QString jpegNamedPng = dir->path() + QStringLiteral("/photo.png");
    QByteArray jpeg = encoded(image, "JPEG");
    ASSERT_FALSE(jpeg.isEmpty());
    ASSERT_TRUE(write(jpegNamedPng, jpeg));
    EXPECT_EQ(ImageSize::read(jpegNamedPng, mounts), QSize(40, 10));
    // A JPEG turned by its EXIF orientation (6: a quarter clockwise) is as tall as it was wide.
    const ImageRotate::JpegOrientation where = ImageRotate::findOrientation(jpeg);
    ASSERT_TRUE(where.valid);
    jpeg.insert(where.insertAt, ImageRotate::exifSegment(6));
    const QString turned = dir->path() + QStringLiteral("/turned.jpg");
    ASSERT_TRUE(write(turned, jpeg));
    EXPECT_EQ(ImageSize::read(turned, mounts), QSize(10, 40));
    // Through a link in the same folder.
    const QString link = dir->path() + QStringLiteral("/link.png");
    ASSERT_TRUE(QFile::link(png, link));
    EXPECT_EQ(ImageSize::read(link, mounts), QSize(40, 10));
}

TEST(ImageSize, AHugeFileIsReadUpToTheBudget)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    // 4 GiB of zeros named like a picture (sparse: nothing is written to disk).
    const QString zeros = dir->path() + QStringLiteral("/huge.png");
    {
        QFile f(zeros);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        ASSERT_TRUE(f.resize(qint64(4) * 1024 * 1024 * 1024));
    }
    QSize size(1, 1);
    QElapsedTimer clock;
    clock.start();
    EXPECT_TRUE(returnsWithin(5000, [&] { size = ImageSize::read(zeros, mounts); })) << "a 4 GiB file was read past the budget";
    EXPECT_FALSE(size.isValid());
    // A real picture at the start of a huge file: its header gives the size at once.
    QImage image(30, 20, QImage::Format_RGB32);
    image.fill(Qt::blue);
    const QString big = dir->path() + QStringLiteral("/big.png");
    {
        QFile f(big);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        ASSERT_TRUE(f.write(encoded(image, "PNG")) > 0);
        ASSERT_TRUE(f.resize(qint64(4) * 1024 * 1024 * 1024));
    }
    EXPECT_TRUE(returnsWithin(5000, [&] { size = ImageSize::read(big, mounts); }));
    EXPECT_EQ(size, QSize(30, 20));
    std::printf("huge files: %lld ms for both reads\n", static_cast<long long>(clock.elapsed()));
}

// The budget is what ends a header that never ends: a PBM whose comment line runs on through 4 GiB of NUL bytes (sparse:
// nothing is written to disk) has the PBM reader ask for one byte after another; at kReadBudget it gets no more and gives
// up. Without the budget the read takes the whole file (over 30 s here). Everything the reading thread uses is its own: a
// read that outlives the test (a failure) touches nothing of it.
TEST(ImageSize, TheBudgetEndsAHeaderThatNeverEnds)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    const QString pbm = dir->path() + QStringLiteral("/endless.pbm");
    {
        QFile f(pbm);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        ASSERT_EQ(f.write("P1\n#", 4), 4);
        ASSERT_TRUE(f.resize(qint64(4) * 1024 * 1024 * 1024));
    }
    ASSERT_EQ(ImageSize::check(pbm, mounts), ImageSize::Refusal::None);
    const auto size = std::make_shared<QSize>(1, 1);
    QElapsedTimer clock;
    clock.start();
    const bool returned = returnsWithin(5000, [size, pbm, mounts] { *size = ImageSize::read(pbm, mounts); });
    std::printf("endless PBM header: %s after %lld ms\n", returned ? "refused" : "still reading", static_cast<long long>(clock.elapsed()));
    ASSERT_TRUE(returned) << "the header was read past the budget";
    EXPECT_FALSE(size->isValid());
}

// A link swapped in at the checked path after the check is never followed by the open, wherever it leads (a network share
// would block the open itself): here even to the checked file (a hard link elsewhere keeps its inode), which the device and
// inode comparison after the open would accept. A picture reached through a link is still read: check() follows the link
// and the file is opened by the path it reached.
TEST(ImageSize, ALinkSwappedInAfterTheCheckIsNeverFollowed)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    QImage image(16, 9, QImage::Format_RGB32);
    image.fill(Qt::yellow);
    const QString pictures = dir->path() + QStringLiteral("/pictures");
    const QString elsewhere = dir->path() + QStringLiteral("/elsewhere");
    ASSERT_TRUE(QDir().mkpath(pictures));
    ASSERT_TRUE(QDir().mkpath(elsewhere));
    const QString png = pictures + QStringLiteral("/swap.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    struct stat checked {};
    QString resolved;
    ASSERT_EQ(ImageSize::check(png, mounts, &checked, &resolved), ImageSize::Refusal::None);
    EXPECT_EQ(QFileInfo(resolved).canonicalFilePath(), QFileInfo(png).canonicalFilePath());
    int fd = ImageSize::openChecked(resolved, checked);
    EXPECT_GE(fd, 0) << "the checked file, unchanged";
    if (fd >= 0)
        ::close(fd);
    // After the check: the checked name becomes a link to the same inode.
    const QString same = elsewhere + QStringLiteral("/same.png");
    ASSERT_EQ(::link(QFile::encodeName(png).constData(), QFile::encodeName(same).constData()), 0);
    ASSERT_EQ(::unlink(QFile::encodeName(png).constData()), 0);
    ASSERT_TRUE(QFile::link(same, png));
    fd = ImageSize::openChecked(resolved, checked);
    EXPECT_EQ(fd, -1) << "the link swapped in after the check was followed";
    if (fd >= 0)
        ::close(fd);
    // A fresh read through that link: checked again, opened by its target's path.
    EXPECT_EQ(ImageSize::read(png, mounts), QSize(16, 9));
}

// A folder above the checked file swapped for a link after the check is never followed either (O_NOFOLLOW alone covers
// the last component only): the link leads to the checked file itself, which the inode comparison would accept. Needs
// openat2 (Linux 5.6); a kernel or sandbox without it skips (the open then falls back to O_NOFOLLOW).
TEST(ImageSize, AFolderSwappedForALinkAfterTheCheckIsNeverFollowed)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    struct open_how probe {};
    probe.flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
    const long probeFd = ::syscall(SYS_openat2, AT_FDCWD, "/", &probe, sizeof probe);
    if (probeFd < 0 && errno == ENOSYS)
        GTEST_SKIP() << "no openat2 here";
    if (probeFd >= 0)
        ::close(static_cast<int>(probeFd));
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    QImage image(7, 5, QImage::Format_RGB32);
    image.fill(Qt::cyan);
    const QString album = dir->path() + QStringLiteral("/album");
    ASSERT_TRUE(QDir().mkpath(album));
    const QString png = album + QStringLiteral("/photo.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    struct stat checked {};
    QString resolved;
    ASSERT_EQ(ImageSize::check(png, mounts, &checked, &resolved), ImageSize::Refusal::None);
    // After the check: the folder moves away and a link to it takes its name (the same file at the end of the path).
    const QString moved = dir->path() + QStringLiteral("/album-moved");
    ASSERT_EQ(::rename(QFile::encodeName(album).constData(), QFile::encodeName(moved).constData()), 0);
    ASSERT_TRUE(QFile::link(moved, album));
    const int fd = ImageSize::openChecked(resolved, checked);
    EXPECT_EQ(fd, -1) << "the folder link swapped in after the check was followed";
    if (fd >= 0)
        ::close(fd);
    // A fresh read through that path: checked again, opened by the path it reaches now.
    EXPECT_EQ(ImageSize::read(png, mounts), QSize(7, 5));
}

namespace
{
// The errno the openat2 stand-in answers with (ENOSYS: a kernel without it; EPERM: a sandbox's seccomp filter).
int openat2Errno = 0;
int openat2Calls = 0;
int refusingOpenat2(const char *, int, quint64)
{
    openat2Calls++;
    errno = openat2Errno;
    return -1;
}
} // namespace

// Where openat2 answers ENOSYS or EPERM, the open falls back to open() with O_NOFOLLOW: the picture is read (no
// Dimensions read would succeed otherwise), a link swapped in at the end of the path after the check is still refused,
// and the inode check still holds. Any other answer of openat2 is a refusal, without a fallback.
TEST(ImageSize, WithoutOpenat2TheOpenFallsBackToNoFollow)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    const FolderStyleStore::Mounts mounts = FolderStyleStore::Mounts::system();
    QImage image(9, 4, QImage::Format_RGB32);
    image.fill(Qt::magenta);
    const QString elsewhere = dir->path() + QStringLiteral("/elsewhere");
    ASSERT_TRUE(QDir().mkpath(elsewhere));
    ImageSize::setOpenat2ForTests(refusingOpenat2);
    for (const int code : {ENOSYS, EPERM}) {
        SCOPED_TRACE(code == ENOSYS ? "ENOSYS" : "EPERM");
        openat2Errno = code;
        const QString png = dir->path() + QStringLiteral("/fallback-%1.png").arg(code);
        ASSERT_TRUE(write(png, encoded(image, "PNG")));
        openat2Calls = 0;
        EXPECT_EQ(ImageSize::read(png, mounts), QSize(9, 4)) << "the fallback opens the checked file";
        EXPECT_EQ(openat2Calls, 1) << "openat2 was asked first";
        struct stat checked {};
        QString resolved;
        ASSERT_EQ(ImageSize::check(png, mounts, &checked, &resolved), ImageSize::Refusal::None);
        // A link to the same inode swapped in after the check: O_NOFOLLOW refuses it.
        const QString same = elsewhere + QStringLiteral("/same-%1.png").arg(code);
        ASSERT_EQ(::link(QFile::encodeName(png).constData(), QFile::encodeName(same).constData()), 0);
        ASSERT_EQ(::unlink(QFile::encodeName(png).constData()), 0);
        ASSERT_TRUE(QFile::link(same, png));
        const int fd = ImageSize::openChecked(resolved, checked);
        EXPECT_EQ(fd, -1) << "the fallback followed a link swapped in at the end of the path";
        if (fd >= 0)
            ::close(fd);
    }
    // Another answer (EACCES): no fallback, the file is not read.
    openat2Errno = EACCES;
    const QString png = dir->path() + QStringLiteral("/refused.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    EXPECT_FALSE(ImageSize::read(png, mounts).isValid());
    ImageSize::setOpenat2ForTests(nullptr);
    EXPECT_EQ(ImageSize::read(png, mounts), QSize(9, 4)) << "the system call is back";
}

TEST(ImageSize, NetworkAndFuseMountsAreNeverLookedAt)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    QImage image(8, 8, QImage::Format_RGB32);
    image.fill(Qt::green);
    const QString share = dir->path() + QStringLiteral("/share");
    ASSERT_TRUE(QDir().mkpath(share));
    const QString png = share + QStringLiteral("/remote.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    // The same real file, on a table that calls its folder a network share or a FUSE mount: refused before any lstat (a
    // missing file there reads NotLocal too, so nothing was looked at to decide).
    for (const QString &type : {QStringLiteral("nfs4"), QStringLiteral("cifs"), QStringLiteral("fuse.sshfs"), QStringLiteral("fuseblk")}) {
        const FolderStyleStore::Mounts remote = mountsWith(share, type);
        EXPECT_EQ(ImageSize::check(png, remote), ImageSize::Refusal::NotLocal) << qPrintable(type);
        EXPECT_EQ(ImageSize::check(share + QStringLiteral("/missing.png"), remote), ImageSize::Refusal::NotLocal) << qPrintable(type);
        EXPECT_EQ(ImageSize::check(share, remote), ImageSize::Refusal::NotLocal) << "the mount point itself, " << qPrintable(type);
        EXPECT_FALSE(ImageSize::read(png, remote).isValid()) << qPrintable(type);
    }
    // A link on a local disk that leads into the share is refused as well.
    const QString link = dir->path() + QStringLiteral("/link.png");
    ASSERT_TRUE(QFile::link(png, link));
    EXPECT_EQ(ImageSize::check(link, mountsWith(share, QStringLiteral("nfs4"))), ImageSize::Refusal::NotLocal);
    // An unknown mount table (no root): nothing is looked at.
    EXPECT_EQ(ImageSize::check(png, FolderStyleStore::Mounts()), ImageSize::Refusal::NotLocal);
}

TEST(ImageSize, TheReaderNeverBlocksItsCaller)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    app();
    const Specials s = makeSpecials(dir->path());
    const QString huge = dir->path() + QStringLiteral("/huge.png");
    {
        QFile f(huge);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        ASSERT_TRUE(f.resize(qint64(4) * 1024 * 1024 * 1024));
    }
    QImage image(12, 34, QImage::Format_RGB32);
    image.fill(Qt::gray);
    const QString png = dir->path() + QStringLiteral("/fine.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    const QString share = dir->path() + QStringLiteral("/share");
    ASSERT_TRUE(QDir().mkpath(share));
    const QString remote = share + QStringLiteral("/remote.png");
    ASSERT_TRUE(write(remote, encoded(image, "PNG")));

    QObject owner;
    QHash<QString, QSize> answers;
    QEventLoop loop;
    const auto ready = [&](const QString &path, QSize size) {
        EXPECT_EQ(QThread::currentThread(), owner.thread()) << "answers arrive on the owner's thread";
        answers.insert(path, size);
        if (answers.size() == 5)
            loop.quit();
    };
    ImageSize::Reader local(&owner, ready);
    ImageSize::Reader network(&owner, ready);
    network.setMountsForTests(mountsWith(share, QStringLiteral("nfs4")));
    // The GUI thread's part: queuing, nothing else (budget 50 ms for the five, measured in microseconds).
    QElapsedTimer clock;
    clock.start();
    local.request(s.fifo);
    local.request(s.zero);
    local.request(huge);
    local.request(png);
    network.request(remote);
    const qint64 queued = clock.nsecsElapsed();
    EXPECT_LT(queued, 50 * 1000 * 1000) << "request() blocked the caller";
    QTimer::singleShot(10000, &loop, &QEventLoop::quit);
    loop.exec();
    std::printf("five requests queued in %lld us, answered in %lld ms\n", static_cast<long long>(queued / 1000), static_cast<long long>(clock.elapsed()));
    ASSERT_EQ(answers.size(), 5);
    EXPECT_FALSE(answers.value(s.fifo).isValid());
    EXPECT_FALSE(answers.value(s.zero).isValid());
    EXPECT_FALSE(answers.value(huge).isValid());
    EXPECT_EQ(answers.value(png), QSize(12, 34));
    EXPECT_FALSE(answers.value(remote).isValid()) << "the share is never read";
}

TEST(ImageSize, NothingArrivesAfterTheOwnerIsGone)
{
    const auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (inside .dev/) is not set";
    app();
    QImage image(5, 5, QImage::Format_RGB32);
    image.fill(Qt::black);
    const QString png = dir->path() + QStringLiteral("/gone.png");
    ASSERT_TRUE(write(png, encoded(image, "PNG")));
    int calls = 0;
    {
        auto owner = std::make_unique<QObject>();
        auto reader = std::make_unique<ImageSize::Reader>(owner.get(), [&calls](const QString &, QSize) { calls++; });
        reader->request(png);
        // As in FolderModel: the reader goes with its owner, before the owner's QObject part.
        reader.reset();
        owner.reset();
    }
    QEventLoop loop;
    QTimer::singleShot(300, &loop, &QEventLoop::quit);
    loop.exec();
    EXPECT_EQ(calls, 0);
}
