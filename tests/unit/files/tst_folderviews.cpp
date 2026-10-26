// Unit tests for apps/files/src/folderviews.{h,cpp} (gtest): the per-folder view settings store of Grassfield Files
// (docs/specs/files.md FP-14, decision F-3). Built and run by scripts/dev/test.sh. The file tests only write under
// GRASSFIELD_TEST_TMP, a directory inside the repository's .dev/ (set by scripts/dev/test.sh); they skip without it.
#include "folderviews.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QThread>

#include <memory>

#include <gtest/gtest.h>

namespace
{
std::unique_ptr<QTemporaryDir> sandbox()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/")))
        return nullptr;
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/folderviews-XXXXXX"));
    return dir->isValid() ? std::move(dir) : nullptr;
}

FolderViews::Entry entry(const QString &mode, int sortKey = -1, int descending = -1)
{
    FolderViews::Entry e;
    e.mode = mode;
    e.sortKey = sortKey;
    e.descending = descending;
    return e;
}

void writeFile(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}
} // namespace

TEST(FolderViews, KeysIgnoreATrailingSlashAndDotSegments)
{
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/Documents/"))), QStringLiteral("file:///home/u/Documents"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/x/../Documents"))), QStringLiteral("file:///home/u/Documents"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///"))), QStringLiteral("file:///"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("trash:/"))), QStringLiteral("trash:/"));
    // A search location keeps its query; a space is encoded the same way whatever the spelling it came with.
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("grassfield-tag:/Red?in=file:///home/u"))),
              FolderViews::keyFor(QUrl(QStringLiteral("grassfield-tag:/Red?in=file:///home/u"))));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/My Files"))), FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/My%20Files"))));
    EXPECT_TRUE(FolderViews::keyFor(QUrl()).isEmpty());
}

TEST(FolderViews, InvalidFieldsReadAsUnset)
{
    const auto e = FolderViews::parse(QJsonDocument::fromJson(R"({"url":"file:///a","mode":"cover","sortKey":7,"descending":"yes"})").object());
    EXPECT_TRUE(e.isEmpty());
    const auto f = FolderViews::parse(QJsonDocument::fromJson(R"({"mode":"list","sortKey":2.5,"descending":false})").object());
    EXPECT_EQ(f.mode, QStringLiteral("list"));
    EXPECT_EQ(f.sortKey, -1);
    EXPECT_EQ(f.descending, 0);
}

TEST(FolderViews, MergeKeepsFieldsThatAreNotSet)
{
    const auto base = entry(QStringLiteral("list"), 2, 1);
    EXPECT_EQ(FolderViews::merged(base, entry(QString(), 0)), entry(QStringLiteral("list"), 0, 1));
    EXPECT_EQ(FolderViews::merged(base, entry(QStringLiteral("gallery"))), entry(QStringLiteral("gallery"), 2, 1));
    EXPECT_EQ(FolderViews::merged(base, entry(QStringLiteral("bogus"), 9, 4)), base);
}

TEST(FolderViews, RoundTripAndMostRecentLast)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("state/files-views.json"));
    FolderViews views(file);
    views.load();
    EXPECT_EQ(views.count(), 0);
    ASSERT_TRUE(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"), 2, 1)));
    ASSERT_TRUE(views.set(QStringLiteral("file:///b"), entry(QStringLiteral("columns"))));
    ASSERT_TRUE(views.set(QStringLiteral("file:///a"), entry(QString(), 0)));
    EXPECT_EQ(QFileInfo(file).permissions() & (QFileDevice::ReadGroup | QFileDevice::ReadOther), QFileDevice::Permissions());

    FolderViews again(file);
    again.load();
    EXPECT_EQ(again.count(), 2);
    EXPECT_EQ(again.entry(QStringLiteral("file:///a")), entry(QStringLiteral("list"), 0, 1));
    EXPECT_EQ(again.entry(QStringLiteral("file:///b")), entry(QStringLiteral("columns")));
    EXPECT_TRUE(again.entry(QStringLiteral("file:///c")).isEmpty());
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    EXPECT_EQ(root.value(QStringLiteral("version")).toInt(), 1);
    const QJsonArray folders = root.value(QStringLiteral("folders")).toArray();
    ASSERT_EQ(folders.size(), 2);
    // The folder set last is listed last (the least recently set one goes first when the store is full).
    EXPECT_EQ(folders.at(1).toObject().value(QStringLiteral("url")).toString(), QStringLiteral("file:///a"));
}

TEST(FolderViews, TheOldestFolderGoesWhenFull)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    QJsonArray folders;
    for (int i = 0; i < FolderViews::kMaxEntries; i++)
        folders.append(FolderViews::serialize(QStringLiteral("file:///f%1").arg(i), entry(QStringLiteral("list"))));
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("folders"), folders);
    writeFile(file, QJsonDocument(root).toJson(QJsonDocument::Compact));
    FolderViews views(file);
    views.load();
    EXPECT_EQ(views.count(), FolderViews::kMaxEntries);
    ASSERT_TRUE(views.set(QStringLiteral("file:///new"), entry(QStringLiteral("gallery"))));
    EXPECT_EQ(views.count(), FolderViews::kMaxEntries);
    EXPECT_TRUE(views.entry(QStringLiteral("file:///f0")).isEmpty());
    EXPECT_FALSE(views.entry(QStringLiteral("file:///f1")).isEmpty());
    EXPECT_EQ(views.entry(QStringLiteral("file:///new")).mode, QStringLiteral("gallery"));
}

TEST(FolderViews, AFileItCannotReadIsNeverOverwritten)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    for (const QByteArray &bytes : {QByteArray("{not json"), QByteArray(R"({"version":2,"folders":[]})"), QByteArray(R"({"version":"one"})"),
                                    QByteArray(R"({"version":1,"folders":{"a":1}})")}) {
        writeFile(file, bytes);
        FolderViews views(file);
        views.load();
        EXPECT_TRUE(views.readOnly()) << bytes.constData();
        QString error;
        EXPECT_FALSE(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list")), &error));
        EXPECT_FALSE(error.isEmpty());
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::ReadOnly));
        EXPECT_EQ(f.readAll(), bytes);
    }
}

TEST(FolderViews, AMissingVersionReadsAsOne)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    writeFile(file, R"({"folders":[{"url":"file:///a","mode":"list"}]})");
    FolderViews views(file);
    views.load();
    EXPECT_FALSE(views.readOnly());
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
}

TEST(FolderViews, AnotherProcessesEntriesAreKept)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews first(file);
    first.load();
    ASSERT_TRUE(first.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))));
    FolderViews second(file);
    second.load();
    // A later modification time than the first store read (the file system's clock may be coarse).
    QThread::msleep(20);
    ASSERT_TRUE(second.set(QStringLiteral("file:///b"), entry(QStringLiteral("gallery"))));
    ASSERT_TRUE(first.set(QStringLiteral("file:///c"), entry(QStringLiteral("columns"))));
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.count(), 3);
    EXPECT_EQ(check.entry(QStringLiteral("file:///b")).mode, QStringLiteral("gallery"));
}

TEST(FolderViews, FieldsOfANewerVersionSurviveAWrite)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    writeFile(file, R"({"version":1,"folders":[{"url":"file:///a","mode":"list","groupBy":"kind"}]})");
    FolderViews views(file);
    views.load();
    ASSERT_TRUE(views.set(QStringLiteral("file:///a"), entry(QString(), 2)));
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject a = QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("folders")).toArray().at(0).toObject();
    EXPECT_EQ(a.value(QStringLiteral("groupBy")).toString(), QStringLiteral("kind"));
    EXPECT_EQ(a.value(QStringLiteral("mode")).toString(), QStringLiteral("list"));
    EXPECT_EQ(a.value(QStringLiteral("sortKey")).toInt(), 2);
}

TEST(FolderViews, OldFoldersMakeRoomUnderTheSizeLimit)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    // 1900 folders of about 1 KB each (long percent-encoded paths): just under 2 MiB, and under kMaxEntries.
    const QString longName = QString(110, QChar(0x6587)); // a CJK character, 9 bytes once percent-encoded
    QJsonArray folders;
    for (int i = 0; i < 1900; i++)
        folders.append(FolderViews::serialize(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f%1/").arg(i) + longName)), entry(QStringLiteral("list"))));
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("folders"), folders);
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Compact);
    ASSERT_LT(bytes.size(), FolderViews::kMaxFileSize);
    ASSERT_GT(bytes.size(), FolderViews::kMaxFileSize - 200 * 1024);
    writeFile(file, bytes);
    FolderViews views(file);
    views.load();
    ASSERT_EQ(views.count(), 1900);
    // 50 more folders of about 4 KB: past the size limit long before the entry limit.
    const QString fresh = FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/new/") + longName + longName + longName + longName));
    for (int i = 0; i < 50; i++)
        ASSERT_TRUE(views.set(fresh + QString::number(i), entry(QStringLiteral("gallery")))) << i;
    EXPECT_LE(QFileInfo(file).size(), FolderViews::kMaxFileSize);
    EXPECT_LT(views.count(), 1950) << "folders went for size, not for count";
    EXPECT_EQ(views.entry(fresh + QStringLiteral("49")).mode, QStringLiteral("gallery"));
    EXPECT_TRUE(views.entry(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f0/") + longName))).isEmpty()) << "the oldest went";
    EXPECT_EQ(views.entry(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f1899/") + longName))).mode, QStringLiteral("list"));
}

TEST(FolderViews, ReadsFollowAnotherProcess)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews reader(file);
    reader.refresh();
    EXPECT_TRUE(reader.entry(QStringLiteral("file:///a")).isEmpty());
    QThread::msleep(20);
    FolderViews writer(file);
    ASSERT_TRUE(writer.set(QStringLiteral("file:///a"), entry(QStringLiteral("columns"))));
    reader.refresh();
    EXPECT_EQ(reader.entry(QStringLiteral("file:///a")).mode, QStringLiteral("columns"));
}
