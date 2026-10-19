// Unit tests for the background pruning of the per-user folder style store (apps/files/src/folderstylestore.cpp):
// canonical resolution against the mount table (symbolic links, network shares), errors, mount point spelling, and the
// exit that never waits for a blocked worker. A fake file system and a fake mount table: nothing here touches a real
// mount or the owner's files.
#include "folderstylestore.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QMutex>
#include <QMutexLocker>
#include <QSet>
#include <QTemporaryDir>
#include <QThread>

#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <mutex>

#include <gtest/gtest.h>

namespace
{
using K = FolderStyleStore::Fs::Kind;

// path -> kind, links -> target text. Anything not listed is Missing; paths in `errors` fail like EACCES.
struct FakeFs {
    QHash<QString, K> kinds;
    QHash<QString, QString> links;
    QSet<QString> errors;
    FolderStyleStore::Fs fs() const
    {
        FolderStyleStore::Fs f;
        f.kindOf = [this](const QString &p) {
            if (errors.contains(p))
                return K::Error;
            return kinds.value(p, K::Missing);
        };
        f.readLink = [this](const QString &p) { return links.value(p); };
        return f;
    }
};

FolderStyleStore::Mounts mountsOf(const char *mountinfo, const char *fstab = "")
{
    return FolderStyleStore::Mounts::parse(mountinfo, fstab);
}

const char *kRoot = "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n";
} // namespace

TEST(FolderStylePrune, ASymlinkIntoANetworkShareIsNeverFollowedIntoIt)
{
    FakeFs fake;
    fake.kinds = {{"/home", K::Dir}, {"/home/u", K::Dir}, {"/home/u/nas", K::Link}, {"/mnt", K::Dir}, {"/mnt/share", K::Dir}};
    fake.links = {{"/home/u/nas", "/mnt/share"}};
    const auto mounts = mountsOf("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:50 / /mnt/share rw - cifs //srv/x rw\n");
    QMutex lock;
    QStringList statted;
    FolderStyleStore::setStatObserverForTests([&](const QString &p) {
        QMutexLocker l(&lock);
        statted.append(p);
    });
    const QStringList gone = FolderStyleStore::goneEntries({"/home/u/nas/Photos", "/home/u/nas/Gone/Deeper", "/home/u/nas"}, mounts, fake.fs(), nullptr);
    FolderStyleStore::setStatObserverForTests(nullptr);
    EXPECT_FALSE(statted.isEmpty());
    for (const QString &p : statted)
        EXPECT_FALSE(p == QLatin1String("/mnt/share") || p.startsWith(QLatin1String("/mnt/share/"))) << "statted inside the share: " << p.toStdString();
    EXPECT_FALSE(gone.contains(QStringLiteral("/home/u/nas/Photos")));
    EXPECT_FALSE(gone.contains(QStringLiteral("/home/u/nas/Gone/Deeper")));
    EXPECT_TRUE(gone.contains(QStringLiteral("/home/u/nas"))) << "the link itself is local: it is no folder any more";
}

TEST(FolderStylePrune, LinkChainsAreResolvedThroughLocalDisksOnly)
{
    FakeFs fake;
    fake.kinds = {{"/home", K::Dir}, {"/home/u", K::Dir}, {"/home/u/a", K::Link}, {"/home/u/b", K::Link}, {"/data", K::Dir},
                  {"/data/real", K::Dir}, {"/data/real/here", K::Dir}, {"/home/u/loop1", K::Link}, {"/home/u/loop2", K::Link}};
    fake.links = {{"/home/u/a", "b"}, {"/home/u/b", "/data/real"}, {"/home/u/loop1", "loop2"}, {"/home/u/loop2", "loop1"}};
    const auto mounts = mountsOf(kRoot);
    const QStringList gone = FolderStyleStore::goneEntries(
        {"/home/u/a/here", "/home/u/a/vanished", "/home/u/b/here/deeper", "/home/u/loop1/x", "/home/u/missing/x", "/home/u/missing"}, mounts, fake.fs(), nullptr);
    EXPECT_FALSE(gone.contains(QStringLiteral("/home/u/a/here"))) << "present through two links";
    EXPECT_TRUE(gone.contains(QStringLiteral("/home/u/a/vanished"))) << "absent from a real local folder";
    EXPECT_TRUE(gone.contains(QStringLiteral("/home/u/b/here/deeper")));
    EXPECT_FALSE(gone.contains(QStringLiteral("/home/u/loop1/x"))) << "a link loop can't be told: kept";
    EXPECT_TRUE(gone.contains(QStringLiteral("/home/u/missing")));
    EXPECT_TRUE(gone.contains(QStringLiteral("/home/u/missing/x"))) << "under a vanished folder";
}

TEST(FolderStylePrune, ALinkThroughALocalFolderToAShareIsKeptAndNotStatted)
{
    // ~/media -> /data/media (local, btrfs); /data/media/nas -> /mnt/share (cifs): two hops, the second is a share.
    FakeFs fake;
    fake.kinds = {{"/home", K::Dir}, {"/home/u", K::Dir}, {"/home/u/media", K::Link}, {"/data", K::Dir}, {"/data/media", K::Dir},
                  {"/data/media/nas", K::Link}, {"/mnt", K::Dir}, {"/mnt/share", K::Dir}};
    fake.links = {{"/home/u/media", "/data/media"}, {"/data/media/nas", "../../mnt/share"}};
    const auto mounts = mountsOf("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 8:33 / /data rw - btrfs /dev/sdc rw\n3 1 0:50 / /mnt/share rw - cifs //srv/x rw\n");
    QMutex lock;
    QStringList statted;
    FolderStyleStore::setStatObserverForTests([&](const QString &p) {
        QMutexLocker l(&lock);
        statted.append(p);
    });
    const QStringList gone = FolderStyleStore::goneEntries({"/home/u/media/nas/Photos"}, mounts, fake.fs(), nullptr);
    FolderStyleStore::setStatObserverForTests(nullptr);
    EXPECT_TRUE(gone.isEmpty());
    EXPECT_TRUE(statted.contains(QStringLiteral("/data/media/nas"))) << "the local link itself was read";
    for (const QString &p : statted)
        EXPECT_FALSE(p.startsWith(QLatin1String("/mnt/share"))) << p.toStdString();
}

TEST(FolderStylePrune, OnlyDoesNotExistCountsAsGone)
{
    FakeFs fake;
    fake.kinds = {{"/home", K::Dir}, {"/home/u", K::Dir}, {"/home/u/locked", K::Dir}};
    fake.errors = {QStringLiteral("/home/u/locked/inside")};
    const QStringList gone = FolderStyleStore::goneEntries({"/home/u/locked/inside", "/home/u/locked/inside/deeper", "/home/u/plain"}, mountsOf(kRoot), fake.fs(), nullptr);
    EXPECT_EQ(gone, QStringList{QStringLiteral("/home/u/plain")}) << "EACCES/EIO and the like keep the entry";
}

TEST(FolderStylePrune, RealLstatErrorsOtherThanNotFoundKeepTheEntry)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString parent = tmp.filePath(QStringLiteral("closed"));
    ASSERT_TRUE(QDir().mkpath(parent + QStringLiteral("/child")));
    ASSERT_EQ(::chmod(QFile::encodeName(parent).constData(), 0), 0);
    const auto mounts = mountsOf(kRoot);
    const QStringList gone = FolderStyleStore::goneEntries({parent + QStringLiteral("/child"), tmp.filePath(QStringLiteral("absent"))}, mounts);
    ::chmod(QFile::encodeName(parent).constData(), 0755);
    EXPECT_EQ(gone, QStringList{tmp.filePath(QStringLiteral("absent"))}) << "a folder under a parent that can't be searched stays";
}

TEST(FolderStylePrune, MountPointsWithATrailingSlashAreNormalised)
{
    const auto m = mountsOf("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 8:33 / /data/ rw - btrfs /dev/sdc rw\n",
                            "/dev/sde1 /backup/ ext4 defaults 0 2\n/dev/sdc /data/ btrfs defaults 0 0\n");
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/backup/x"))) << "a declared mount point with a trailing slash that is not mounted";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/backup")));
    EXPECT_TRUE(m.isLocalAndMounted(QStringLiteral("/data/x"))) << "and one that is mounted";
}

TEST(FolderStylePrune, ExitDoesNotWaitForAWorkerBlockedInAStat)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString file = tmp.filePath(QStringLiteral("folder-styles.json"));
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("{\"version\":1,\"serial\":1,\"folders\":{\"/home/u/Photos\":{\"color\":\"#e5484d\"},\"/home/u/Music\":{\"color\":\"#3fae5a\"}}}");
    f.close();
    FakeFs fake;
    fake.kinds = {{"/home", K::Dir}, {"/home/u", K::Dir}, {"/home/u/Photos", K::Dir}, {"/home/u/Music", K::Dir}};
    std::mutex m;
    std::condition_variable cv;
    bool entered = false, release = false;
    std::atomic<int> calls{0};
    FolderStyleStore::setStatObserverForTests([&](const QString &) {
        ++calls;
        std::unique_lock<std::mutex> l(m);
        entered = true;
        cv.notify_all();
        cv.wait(l, [&] { return release; }); // a dead hard mount: the stat does not return
    });
    QElapsedTimer timer;
    {
        FolderStyleStore store(file);
        store.setMountsForTests(mountsOf(kRoot));
        store.setFsForTests(fake.fs());
        ASSERT_EQ(store.fallbackCount(), 2);
        store.startPrune(true);
        {
            std::unique_lock<std::mutex> l(m);
            ASSERT_TRUE(cv.wait_for(l, std::chrono::seconds(5), [&] { return entered; }));
        }
        timer.start();
    } // the destructor runs here while the worker is blocked
    const qint64 took = timer.elapsed();
    EXPECT_LT(took, 1000) << "the destructor waited for the blocked worker (" << took << " ms)";
    {
        std::lock_guard<std::mutex> l(m);
        release = true;
    }
    cv.notify_all();
    QThread::msleep(150);
    EXPECT_EQ(calls.load(), 1) << "the abandoned worker stopped at its next step (one stat, no more)";
    FolderStyleStore::setStatObserverForTests(nullptr);
}
