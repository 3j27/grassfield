// Unit tests for apps/files/src/taglogic.{h,cpp} and tagstore.{h,cpp} (gtest). Built and run by scripts/dev/test.sh.
// The extended attribute tests only touch files they create under GRASSFIELD_TEST_TMP, a directory inside the
// repository's .dev/ (set by scripts/dev/test.sh); they skip without it, or when that filesystem has no user
// extended attributes.
#include "taglogic.h"
#include "tagstore.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <cerrno>
#include <memory>
#include <sys/xattr.h>
#include <unistd.h>

#include <gtest/gtest.h>

namespace
{
const QStringList kKeys = {QStringLiteral("Red"), QStringLiteral("Orange"), QStringLiteral("Yellow"), QStringLiteral("Green"),
                           QStringLiteral("Blue"), QStringLiteral("Purple"), QStringLiteral("Gray")};

// A fresh directory under GRASSFIELD_TEST_TMP (inside .dev/), or nullptr with the reason to skip.
std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/tags-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

QString makeFile(const QTemporaryDir &dir, const QString &name)
{
    const QString path = dir.filePath(name);
    QFile f(path);
    if (f.open(QIODevice::WriteOnly))
        f.write("x\n");
    return path;
}

QByteArray rawAttribute(const QString &path, int *error)
{
    char buffer[4096];
    const ssize_t n = ::lgetxattr(QFile::encodeName(path).constData(), "user.xdg.tags", buffer, sizeof buffer);
    *error = n < 0 ? errno : 0;
    return n < 0 ? QByteArray() : QByteArray(buffer, int(n));
}
} // namespace

// --- TagLogic: parse / serialize --------------------------------------------------------------------------------

TEST(TagParse, CommaSeparatedTrimmedWithoutEmptiesOrDuplicates)
{
    EXPECT_EQ(TagLogic::parse("Red,Work"), (QStringList{QStringLiteral("Red"), QStringLiteral("Work")}));
    EXPECT_EQ(TagLogic::parse(" Red , Work ,,Red,"), (QStringList{QStringLiteral("Red"), QStringLiteral("Work")}));
    EXPECT_TRUE(TagLogic::parse("").isEmpty());
    EXPECT_TRUE(TagLogic::parse(" , ,").isEmpty());
    // Exact duplicates only: case variants of a free tag are distinct tags (other tools write them).
    EXPECT_EQ(TagLogic::parse("work,Work"), (QStringList{QStringLiteral("work"), QStringLiteral("Work")}));
}

TEST(TagParse, Utf8AndHierarchicalTagsOfOtherTools)
{
    EXPECT_EQ(TagLogic::parse("Été,Projets/2026"), (QStringList{QString::fromUtf8("Été"), QStringLiteral("Projets/2026")}));
    // Invalid UTF-8 never breaks parsing.
    EXPECT_EQ(TagLogic::parse(QByteArray("ok,\xff\xfe")).size(), 2);
}

TEST(TagSerialize, JoinsWithCommasAndNeutralisesSeparators)
{
    EXPECT_EQ(TagLogic::serialize({QStringLiteral("Red"), QStringLiteral("Work")}), QByteArray("Red,Work"));
    EXPECT_EQ(TagLogic::serialize({QStringLiteral("a,b"), QStringLiteral("line\nbreak"), QStringLiteral("  ")}), QByteArray("a b,line break"));
    EXPECT_EQ(TagLogic::serialize({QStringLiteral("Red"), QStringLiteral(" Red ")}), QByteArray("Red"));
    EXPECT_TRUE(TagLogic::serialize({}).isEmpty());
    EXPECT_EQ(TagLogic::serialize({QString::fromUtf8("Été")}), QByteArray("\xc3\x89t\xc3\xa9"));
}

TEST(TagSerialize, RoundTrip)
{
    const QStringList tags = {QStringLiteral("Blue"), QStringLiteral("Clients/Acme"), QString::fromUtf8("à faire")};
    EXPECT_EQ(TagLogic::parse(TagLogic::serialize(tags)), tags);
}

// --- TagLogic: colour tags -----------------------------------------------------------------------------------

TEST(TagColors, SevenKeysInPaletteOrderMatchedCaseInsensitively)
{
    for (int i = 0; i < TagLogic::kColorCount; ++i) {
        EXPECT_EQ(TagLogic::colorKey(i), kKeys[i]);
        EXPECT_EQ(TagLogic::colorIndex(kKeys[i]), i);
        EXPECT_EQ(TagLogic::colorIndex(kKeys[i].toLower()), i);
        EXPECT_EQ(TagLogic::colorIndex(QLatin1Char(' ') + kKeys[i].toUpper() + QLatin1Char(' ')), i);
    }
    EXPECT_EQ(TagLogic::colorIndex(QStringLiteral("Work")), -1);
    EXPECT_EQ(TagLogic::colorIndex(QStringLiteral("Grey")), -1);
    EXPECT_TRUE(TagLogic::colorKey(-1).isEmpty());
    EXPECT_TRUE(TagLogic::colorKey(7).isEmpty());
    // Without a translator the names are the keys; free tags show as stored.
    EXPECT_EQ(TagLogic::displayName(QStringLiteral("purple")), QStringLiteral("Purple"));
    EXPECT_EQ(TagLogic::displayName(QStringLiteral("Work")), QStringLiteral("Work"));
}

TEST(TagColors, AddAndRemoveKeepOtherTags)
{
    const QStringList tags = {QStringLiteral("Work"), QStringLiteral("red")};
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("Red"), true), tags); // already there, any case
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("Blue"), true), (QStringList{QStringLiteral("Work"), QStringLiteral("red"), QStringLiteral("Blue")}));
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("blue"), true).last(), QStringLiteral("Blue")); // stored under its key
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("RED"), false), QStringList{QStringLiteral("Work")});
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("work"), false), tags); // free tags compare exactly
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral("Work"), false), QStringList{QStringLiteral("red")});
    EXPECT_EQ(TagLogic::withTag(tags, QStringLiteral(" "), true), tags);
    EXPECT_TRUE(TagLogic::hasTag(tags, QStringLiteral("RED")));
    EXPECT_FALSE(TagLogic::hasTag(tags, QStringLiteral("work")));
}

TEST(TagColors, DisplayOrderAndDots)
{
    const QStringList tags = {QStringLiteral("Work"), QStringLiteral("blue"), QStringLiteral("Red"), QStringLiteral("Home")};
    EXPECT_EQ(TagLogic::displayOrder(tags), (QStringList{QStringLiteral("Red"), QStringLiteral("Blue"), QStringLiteral("Work"), QStringLiteral("Home")}));
    EXPECT_EQ(TagLogic::colorIndices(tags), (QList<int>{0, 4}));
    EXPECT_TRUE(TagLogic::colorIndices({QStringLiteral("Work")}).isEmpty());
}

TEST(TagColors, SelectionStates)
{
    const QList<QStringList> selection = {{QStringLiteral("Red"), QStringLiteral("Blue")}, {QStringLiteral("Red")}};
    EXPECT_EQ(TagLogic::colorStates(selection), (QList<int>{2, 0, 0, 0, 1, 0, 0}));
    EXPECT_EQ(TagLogic::colorStates({}), QList<int>(7, 0));
}

// --- TagLogic: tag search locations -------------------------------------------------------------------------------

TEST(TagSearchUrl, CarriesTagAndFolder)
{
    const QUrl folder = QUrl::fromLocalFile(QStringLiteral("/home/u/My Docs & more?#"));
    const QUrl url = TagLogic::searchUrl(QStringLiteral("Clients/Acme & co"), folder);
    EXPECT_TRUE(TagLogic::isSearchUrl(url));
    EXPECT_EQ(url.scheme(), QStringLiteral("grassfield-tag"));
    EXPECT_EQ(TagLogic::searchTag(url), QStringLiteral("Clients/Acme & co"));
    EXPECT_EQ(TagLogic::searchFolder(url), folder);
    // Survives a round trip through its string form (history, tabs).
    const QUrl again(url.toString(QUrl::FullyEncoded));
    EXPECT_EQ(TagLogic::searchTag(again), QStringLiteral("Clients/Acme & co"));
    EXPECT_EQ(TagLogic::searchFolder(again), folder);
    EXPECT_FALSE(TagLogic::isSearchUrl(folder));
    EXPECT_FALSE(TagLogic::isSearchUrl(QUrl(QStringLiteral("grassfield-tag:/"))));
    EXPECT_TRUE(TagLogic::searchFolder(folder).isEmpty());
}

// --- TagStore: user.xdg.tags on a file of the test sandbox ----------------------------------------------------

TEST(TagStore, WriteReadRemoveOnALocalFile)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("report.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    EXPECT_EQ(TagStore::support(file), TagStore::Support::Supported);
    EXPECT_TRUE(TagStore::read(file).isEmpty());

    QString error;
    ASSERT_TRUE(TagStore::write(file, {QStringLiteral("Red"), QStringLiteral("Work")}, &error)) << qPrintable(error);
    int err = 0;
    EXPECT_EQ(rawAttribute(file, &err), QByteArray("Red,Work")); // the freedesktop format, as Dolphin writes it
    EXPECT_EQ(TagStore::read(file), (QStringList{QStringLiteral("Red"), QStringLiteral("Work")}));

    // An empty list removes the attribute (twice is fine).
    ASSERT_TRUE(TagStore::write(file, {}, &error)) << qPrintable(error);
    rawAttribute(file, &err);
    EXPECT_EQ(err, ENODATA);
    EXPECT_TRUE(TagStore::write(file, {}, &error));
    EXPECT_TRUE(TagStore::read(file).isEmpty());
}

TEST(TagStore, KeepsTagsOfOtherToolsAndLongValues)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("notes.md"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    // Written by another tool.
    const QByteArray foreign = QByteArray("Projets/2026, \xc3\x89t\xc3\xa9");
    ASSERT_EQ(::lsetxattr(QFile::encodeName(file).constData(), "user.xdg.tags", foreign.constData(), size_t(foreign.size()), 0), 0);
    QStringList tags = TagStore::read(file);
    EXPECT_EQ(tags, (QStringList{QStringLiteral("Projets/2026"), QString::fromUtf8("Été")}));
    ASSERT_TRUE(TagStore::write(file, TagLogic::withTag(tags, QStringLiteral("Green"), true)));
    EXPECT_EQ(TagStore::read(file), (QStringList{QStringLiteral("Projets/2026"), QString::fromUtf8("Été"), QStringLiteral("Green")}));

    // Longer than the first read buffer.
    QStringList many;
    for (int i = 0; i < 300; ++i)
        many << QStringLiteral("tag-%1").arg(i);
    ASSERT_TRUE(TagStore::write(file, many));
    EXPECT_EQ(TagStore::read(file), many);
}

TEST(TagStore, LinksAndMissingFilesAreNotTaggable)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString target = makeFile(*dir, QStringLiteral("target.txt"));
    const QString link = dir->filePath(QStringLiteral("link.txt"));
    ASSERT_EQ(::symlink(QFile::encodeName(target).constData(), QFile::encodeName(link).constData()), 0);
    EXPECT_EQ(TagStore::support(link), TagStore::Support::Link);
    EXPECT_EQ(TagStore::support(dir->filePath(QStringLiteral("absent"))), TagStore::Support::Missing);
    if (TagStore::support(target) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    // Writing through the link never tags the target (Linux refuses user attributes on links).
    QString error;
    EXPECT_FALSE(TagStore::write(link, {QStringLiteral("Red")}, &error));
    EXPECT_FALSE(error.isEmpty());
    EXPECT_TRUE(TagStore::read(target).isEmpty());
    EXPECT_FALSE(TagStore::write(dir->filePath(QStringLiteral("absent")), {QStringLiteral("Red")}));
}

TEST(TagStore, FoldersCarryTagsToo)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString folder = dir->filePath(QStringLiteral("Projects"));
    ASSERT_TRUE(QDir().mkpath(folder));
    if (TagStore::support(folder) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    ASSERT_TRUE(TagStore::write(folder, {QStringLiteral("Orange")}));
    EXPECT_EQ(TagStore::read(folder), QStringList{QStringLiteral("Orange")});
}
