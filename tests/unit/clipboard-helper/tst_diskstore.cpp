// The clipboard stores on disk (ADR-0034 §5): 0700 directories and 0600 files whatever the umask, bounded reads, a store that
// breaks a rule deleted (never followed through a link), an item file that does only that item, a newer index left alone.
#include "diskstore.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

using namespace ClipLogic;

namespace
{
mode_t modeOf(const QString &path)
{
    struct stat st {};
    if (::lstat(QFile::encodeName(path).constData(), &st) != 0)
        return 0;
    return st.st_mode & 07777;
}

Item text(const QByteArray &id, const QString &plain, qint64 at)
{
    Item it;
    it.id = id;
    it.kind = Kind::Text;
    it.plain = plain;
    it.parts = {{"text/html", "<b>" + plain.toUtf8() + "</b>"}};
    it.title = titleOf(plain);
    it.hash = hashOf(Kind::Text, plain.toUtf8());
    it.copiedAtMs = at;
    it.bootAtMs = at;
    it.bootId = "boot";
    it.pinnedAtMs = at + 1;
    it.app = QStringLiteral("org.example.App");
    return it;
}

// The umask the helper does NOT rely on: files must still be 0600.
struct Umask {
    Umask() { old = ::umask(022); }
    ~Umask() { ::umask(old); }
    mode_t old;
};
} // namespace

TEST(DiskStore, RoundTripAndModes)
{
    Umask umask;
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/clipboard/pinned");
    DiskStore store(dir);
    QList<Item> items;
    items << text("00000000000000a1", QStringLiteral("first"), 100);
    ASSERT_TRUE(store.save(items.last(), items));
    Item files;
    files.id = "00000000000000a2";
    files.kind = Kind::Files;
    files.files = {QStringLiteral("/home/u/a b.txt")};
    files.plain = files.files.join(QLatin1Char('\n'));
    files.parts = {{"text/uri-list", uriList(files.files)}};
    files.pinnedAtMs = 5;
    items << files;
    ASSERT_TRUE(store.save(items.last(), items));
    Item image;
    image.id = "00000000000000a3";
    image.kind = Kind::Image;
    image.imageFormat = "png";
    image.parts = {{"image/png", QByteArray("\x89PNG not checked here")}};
    image.pinnedAtMs = 6;
    items << image;
    ASSERT_TRUE(store.save(items.last(), items));

    EXPECT_EQ(modeOf(dir), mode_t(0700));
    EXPECT_EQ(modeOf(dir + QStringLiteral("/index.json")), mode_t(0600));
    EXPECT_EQ(modeOf(dir + QStringLiteral("/00000000000000a1.item")), mode_t(0600));

    DiskStore again(dir);
    const DiskStore::Loaded loaded = again.load();
    ASSERT_EQ(loaded.status, DiskStore::Status::Loaded);
    ASSERT_EQ(loaded.items.size(), 3);
    EXPECT_EQ(loaded.items.at(0).plain, QStringLiteral("first"));
    EXPECT_EQ(loaded.items.at(0).parts.first().mime, QByteArray("text/html"));
    EXPECT_EQ(loaded.items.at(0).app, QStringLiteral("org.example.App"));
    EXPECT_EQ(loaded.items.at(0).pinnedAtMs, 101);
    EXPECT_EQ(loaded.items.at(1).files, files.files);
    EXPECT_EQ(loaded.items.at(2).imageFormat, QByteArray("png"));

    ASSERT_TRUE(again.removeItem("00000000000000a2", {loaded.items.at(0), loaded.items.at(2)}));
    EXPECT_FALSE(QFile::exists(dir + QStringLiteral("/00000000000000a2.item")));
    ASSERT_TRUE(again.saveIndex({}));
    EXPECT_FALSE(QFileInfo::exists(dir)) << "no empty store is left behind";
}

TEST(DiskStore, BrokenRulesDeleteTheStore)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/pinned");
    QList<Item> items{text("00000000000000b1", QStringLiteral("x"), 1)};

    // An index that is not 0600.
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    ::chmod(QFile::encodeName(dir + QStringLiteral("/index.json")).constData(), 0644);
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);
    EXPECT_FALSE(QFileInfo::exists(dir));

    // A directory that is not 0700.
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    ::chmod(QFile::encodeName(dir).constData(), 0755);
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);

    // An index over 1 MiB, and one that is not JSON.
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    {
        QFile f(dir + QStringLiteral("/index.json"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray(DiskStore::kMaxIndexBytes + 1, ' '));
    }
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    {
        QFile f(dir + QStringLiteral("/index.json"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("{not json");
    }
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);

    // A symlinked index: deleted, the target untouched.
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    const QString target = tmp.path() + QStringLiteral("/target.json");
    {
        QFile f(target);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("{\"version\":1,\"items\":[]}");
    }
    QFile::remove(dir + QStringLiteral("/index.json"));
    ASSERT_TRUE(QFile::link(target, dir + QStringLiteral("/index.json")));
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);
    EXPECT_TRUE(QFile::exists(target));

    // The store directory itself a link: only the link goes.
    const QString elsewhere = tmp.path() + QStringLiteral("/elsewhere");
    ASSERT_TRUE(QDir().mkpath(elsewhere));
    ::chmod(QFile::encodeName(elsewhere).constData(), 0700);
    ASSERT_TRUE(QFile::link(elsewhere, dir));
    EXPECT_EQ(DiskStore(dir).load().status, DiskStore::Status::Deleted);
    EXPECT_FALSE(QFileInfo(dir).isSymLink());
    EXPECT_TRUE(QFileInfo::exists(elsewhere));
}

TEST(DiskStore, ABrokenItemGoesAlone)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/pinned");
    QList<Item> items{text("00000000000000c1", QStringLiteral("one"), 1), text("00000000000000c2", QStringLiteral("two"), 2)};
    DiskStore store(dir);
    ASSERT_TRUE(store.save(items.at(0), items));
    ASSERT_TRUE(store.save(items.at(1), items));
    {
        QFile f(dir + QStringLiteral("/00000000000000c1.item"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write("GFCLIP1\n1\ntext/plain;charset=utf-8\n999\nshort");
    }
    const DiskStore::Loaded loaded = DiskStore(dir).load();
    ASSERT_EQ(loaded.status, DiskStore::Status::Loaded);
    EXPECT_EQ(loaded.dropped, 1);
    ASSERT_EQ(loaded.items.size(), 1);
    EXPECT_EQ(loaded.items.first().plain, QStringLiteral("two"));
    EXPECT_FALSE(QFile::exists(dir + QStringLiteral("/00000000000000c1.item")));
}

TEST(DiskStore, NewerIndexIsLeftAlone)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/pinned");
    QList<Item> items{text("00000000000000d1", QStringLiteral("one"), 1)};
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    {
        QFile f(dir + QStringLiteral("/index.json"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write("{\"version\":2,\"items\":[]}");
    }
    DiskStore store(dir);
    EXPECT_EQ(store.load().status, DiskStore::Status::Newer);
    EXPECT_TRUE(store.readOnly());
    EXPECT_FALSE(store.save(items.first(), items));
    store.deleteAll();
    EXPECT_TRUE(QFile::exists(dir + QStringLiteral("/index.json")));
}

TEST(DiskStore, ItemFiles)
{
    EXPECT_TRUE(DiskStore::validId("0123456789abcdef"));
    EXPECT_FALSE(DiskStore::validId("../../etc/passwd"));
    EXPECT_FALSE(DiskStore::validId("0123456789ABCDEF"));
    Item it = text("00000000000000e1", QStringLiteral("é"), 1);
    Item back;
    ASSERT_TRUE(DiskStore::decodeItem(DiskStore::encodeItem(it), Kind::Text, &back));
    EXPECT_EQ(back.plain, it.plain);
    EXPECT_FALSE(DiskStore::decodeItem(DiskStore::encodeItem(it) + "x", Kind::Text, &back)) << "trailing bytes";
    EXPECT_FALSE(DiskStore::decodeItem(DiskStore::encodeItem(it), Kind::Image, &back)) << "the kind decides the parts";
}

TEST(DiskStore, DeleteAllTouchesOnlyItsFiles)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/history");
    QList<Item> items{text("00000000000000f1", QStringLiteral("one"), 1)};
    ASSERT_TRUE(DiskStore(dir).save(items.first(), items));
    {
        QFile f(dir + QStringLiteral("/notes.txt"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    }
    DiskStore(dir).deleteAll();
    EXPECT_FALSE(QFile::exists(dir + QStringLiteral("/index.json")));
    EXPECT_TRUE(QFile::exists(dir + QStringLiteral("/notes.txt"))) << "a file that is not the store's is left";
}
