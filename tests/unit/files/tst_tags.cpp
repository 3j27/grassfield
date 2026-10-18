// Unit tests for apps/files/src/taglogic.{h,cpp} and tagstore.{h,cpp} (gtest). Built and run by scripts/dev/test.sh.
// The extended attribute tests only touch files they create under GRASSFIELD_TEST_TMP, a directory inside the
// repository's .dev/ (set by scripts/dev/test.sh); they skip without it, or when that filesystem has no user
// extended attributes.
#include "taglogic.h"
#include "tagstore.h"

#include <QDir>
#include <QThread>
#include <QFile>
#include <QTemporaryDir>

#include <cerrno>
#include <memory>
#include <sys/stat.h>
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

// --- Editing keeps what other applications wrote (review of 5bc1343) ------------------------------------------

namespace
{
// The reviewer's value: spaces, duplicates, invalid UTF-8, a line break inside an entry, a lower-case colour name.
const QByteArray kForeign = QByteArray(" Bar ,foo,foo,\xFF\xFE,two\x0Alines,red");
} // namespace

TEST(TagApply, AddingAppendsOneEntryAndKeepsEveryOtherByteAsStored)
{
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral("Blue"), true), kForeign + ",Blue");
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral("blue"), true), kForeign + ",Blue"); // stored under its key
    EXPECT_EQ(TagLogic::applyTag("", QStringLiteral("Red"), true), QByteArray("Red"));
    EXPECT_EQ(TagLogic::applyTag("Work", QStringLiteral("Work"), true), QByteArray("Work")); // already there
    EXPECT_EQ(TagLogic::applyTag(" Red ", QStringLiteral("Red"), true), QByteArray(" Red ")); // spaces do not make it another tag
    // A foreign lower-case "red" is the colour Red already (colour names match without regard to case): not added twice.
    EXPECT_EQ(TagLogic::applyTag("red", QStringLiteral("Red"), true), QByteArray("red"));
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral("Red"), true), kForeign);
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral(" "), true), kForeign);
}

TEST(TagApply, RemovingTakesOutTheNamedEntriesOnly)
{
    // Removing Red takes out every spelling of it (the user removes the colour); every other entry keeps its bytes.
    const QByteArray rest(" Bar ,foo,foo,\xFF\xFE,two\x0Alines");
    EXPECT_EQ(TagLogic::applyTag(kForeign + ",Red", QStringLiteral("Red"), false), rest);
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral("Red"), false), rest);
    EXPECT_EQ(TagLogic::applyTag("red", QStringLiteral("Red"), false), QByteArray());
    EXPECT_EQ(TagLogic::applyTag("Projects,RED,Kept Thing", QStringLiteral("Red"), false), QByteArray("Projects,Kept Thing"));
    // Both entries of an exact duplicate go; the others keep their bytes and order.
    EXPECT_EQ(TagLogic::applyTag(kForeign, QStringLiteral("foo"), false), QByteArray(" Bar ,\xFF\xFE,two\x0Alines,red"));
    EXPECT_EQ(TagLogic::applyTag("a, Red ,b", QStringLiteral("Red"), false), QByteArray("a,b"));
    EXPECT_TRUE(TagLogic::applyTag("Red", QStringLiteral("Red"), false).isEmpty());
    EXPECT_EQ(TagLogic::applyTag("Work", QStringLiteral("work"), false), QByteArray("Work")); // free tags exactly
}

TEST(TagApply, MenuAndToggleUseOneRuleForColours)
{
    // The menu's check (colorStates) and the toggle (ownsTag then applyTag) agree on a foreign "red": Red shows checked,
    // one click removes it, a second adds the key back.
    const QByteArray stored = "red";
    EXPECT_TRUE(TagLogic::ownsTag(stored, QStringLiteral("Red")));
    EXPECT_EQ(TagLogic::colorStates({TagLogic::parse(stored)}).at(0), 2);
    QByteArray next = TagLogic::applyTag(stored, QStringLiteral("Red"), false);
    EXPECT_TRUE(next.isEmpty());
    next = TagLogic::applyTag(next, QStringLiteral("Red"), true);
    EXPECT_EQ(next, QByteArray("Red"));
}

TEST(TagApply, OwnsTheEntryByTheRuleOfItsKind)
{
    EXPECT_TRUE(TagLogic::ownsTag("a, Red ,b", QStringLiteral("Red")));
    EXPECT_TRUE(TagLogic::ownsTag("red", QStringLiteral("Red")));
    EXPECT_FALSE(TagLogic::ownsTag("", QStringLiteral("Red")));
    EXPECT_TRUE(TagLogic::ownsTag("Work", QStringLiteral("Work")));
    EXPECT_FALSE(TagLogic::ownsTag("Work", QStringLiteral("work")));
}

TEST(TagKnown, TagsRemovedFromTheSidebarStayOffIt)
{
    const QStringList hidden = {QStringLiteral("Work")};
    const QStringList seen = {QStringLiteral("Work"), QStringLiteral("Blue"), QStringLiteral("Home")};
    EXPECT_EQ(TagLogic::mergeKnown({}, hidden, seen, 64), (QStringList{QStringLiteral("Blue"), QStringLiteral("Home")}));
    EXPECT_EQ(TagLogic::mergeKnown({}, {}, seen, 64), (QStringList{QStringLiteral("Blue"), QStringLiteral("Work"), QStringLiteral("Home")}));
    EXPECT_EQ(TagLogic::mergeKnown({}, {QStringLiteral("red")}, {QStringLiteral("Red")}, 64), QStringList()); // a colour, any case
    EXPECT_EQ(TagLogic::mergeKnown({}, {}, seen, 2).size(), 2);
}

TEST(TagKnown, AHiddenTagComesBackWhenShownAgain)
{
    const QStringList hidden = {QStringLiteral("Work"), QStringLiteral("Home")};
    // Seen again while hidden: stays off the sidebar.
    EXPECT_TRUE(TagLogic::mergeKnown({}, hidden, {QStringLiteral("Work")}, 64).isEmpty());
    // Show Hidden Tag: leaves the hidden list (the others stay) and is listed at once.
    const QStringList left = TagLogic::withTag(hidden, QStringLiteral("Work"), false);
    EXPECT_EQ(left, QStringList{QStringLiteral("Home")});
    EXPECT_EQ(TagLogic::mergeKnown({}, left, {QStringLiteral("Work")}, 64), QStringList{QStringLiteral("Work")});
}

TEST(TagStore, AFailedReadIsNotTakenForNoTags)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("unreadable.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    QByteArray value = "stale";
    QString error;
    // No attribute: ok, no tags.
    EXPECT_TRUE(TagStore::readRawChecked(file, &value, &error));
    EXPECT_TRUE(value.isEmpty());
    ASSERT_TRUE(TagStore::writeRaw(file, "Projects,Blue,Kept Thing"));
    ASSERT_TRUE(TagStore::readRawChecked(file, &value, &error));
    EXPECT_EQ(value, QByteArray("Projects,Blue,Kept Thing"));
    // Longer than a small buffer.
    const QByteArray longValue = QByteArray("Tag,").repeated(600) + "End";
    ASSERT_TRUE(TagStore::writeRaw(file, longValue));
    ASSERT_TRUE(TagStore::readRawChecked(file, &value, &error));
    EXPECT_EQ(value, longValue);
    // Write-only file (0200): the attribute cannot be read: an error, not an empty value to build a write on.
    if (::geteuid() != 0) {
        ASSERT_TRUE(TagStore::writeRaw(file, "Projects,Blue,Kept Thing"));
        ASSERT_EQ(::chmod(QFile::encodeName(file).constData(), 0200), 0);
        error.clear();
        EXPECT_FALSE(TagStore::readRawChecked(file, &value, &error));
        EXPECT_FALSE(error.isEmpty());
        EXPECT_TRUE(value.isEmpty());
        ASSERT_EQ(::chmod(QFile::encodeName(file).constData(), 0644), 0);
        EXPECT_EQ(TagStore::readRaw(file), QByteArray("Projects,Blue,Kept Thing")); // nothing was written
    }
    // A file that vanished is an error too.
    EXPECT_FALSE(TagStore::readRawChecked(dir->filePath(QStringLiteral("absent")), &value, &error));
}

TEST(TagStore, CacheSeesAnotherApplicationsChangeInsideTheWindow)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("external.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    ASSERT_TRUE(TagStore::writeRaw(file, "Work"));
    TagStore::Cache cache(600000);
    EXPECT_EQ(cache.info(file).tags, QStringList{QStringLiteral("Work")});
    // Another application sets Red (no invalidate): the very next lookup shows it. The kernel stamps ctime at a coarse
    // tick, so wait past one.
    QThread::msleep(30);
    ASSERT_TRUE(TagStore::writeRaw(file, "Work,Red"));
    EXPECT_EQ(cache.info(file).tags, (QStringList{QStringLiteral("Work"), QStringLiteral("Red")}));
    EXPECT_EQ(TagLogic::colorStates({cache.info(file).tags}).at(0), 2);
    // A file that appears where there was none shows too.
    const QString later = dir->filePath(QStringLiteral("later.txt"));
    EXPECT_EQ(cache.info(later).support, TagStore::Support::Missing);
    makeFile(*dir, QStringLiteral("later.txt"));
    EXPECT_NE(cache.info(later).support, TagStore::Support::Missing);
}

TEST(TagStore, RawValueRoundTripsByteForByte)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("raw.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    ASSERT_TRUE(TagStore::writeRaw(file, kForeign));
    EXPECT_EQ(TagStore::readRaw(file), kForeign);
    // Add then remove a colour (the foreign value holds a "red" already, which is Red: use Blue): the foreign bytes come back untouched.
    ASSERT_TRUE(TagStore::writeRaw(file, TagLogic::applyTag(TagStore::readRaw(file), QStringLiteral("Blue"), true)));
    EXPECT_EQ(TagStore::readRaw(file), kForeign + ",Blue");
    ASSERT_TRUE(TagStore::writeRaw(file, TagLogic::applyTag(TagStore::readRaw(file), QStringLiteral("Blue"), false)));
    EXPECT_EQ(TagStore::readRaw(file), kForeign);
    ASSERT_TRUE(TagStore::writeRaw(file, QByteArray()));
    EXPECT_TRUE(TagStore::readRaw(file).isEmpty());
}

TEST(TagStore, CacheAnswersWithoutTouchingTheFileUntilInvalidatedOrExpired)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("cached.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    ASSERT_TRUE(TagStore::writeRaw(file, "Red,Work"));
    TagStore::Cache cache(60000);
    EXPECT_EQ(cache.info(file).support, TagStore::Support::Supported);
    EXPECT_EQ(cache.info(file).tags, (QStringList{QStringLiteral("Red"), QStringLiteral("Work")}));
    // An unchanged file is answered from the cache; a changed one is probed again (CacheSeesAnotherApplicationsChange...).
    // Dropping the entry always probes again.
    ASSERT_TRUE(TagStore::writeRaw(file, "Blue"));
    cache.invalidate(file);
    EXPECT_EQ(cache.info(file).tags, QStringList{QStringLiteral("Blue")});
    EXPECT_EQ(cache.info(file).raw, QByteArray("Blue"));
    // An entry older than the time to live is probed again.
    TagStore::Cache expiring(0);
    EXPECT_EQ(expiring.info(file).tags, QStringList{QStringLiteral("Blue")});
    ASSERT_TRUE(TagStore::writeRaw(file, "Gray"));
    EXPECT_EQ(expiring.info(file).tags, QStringList{QStringLiteral("Gray")});
    // The cap clears the cache instead of growing without bound.
    TagStore::Cache small(60000, 2);
    for (int i = 0; i < 5; ++i)
        small.info(dir->filePath(QStringLiteral("absent-%1").arg(i)));
    EXPECT_EQ(small.info(file).support, TagStore::Support::Supported);
}

TEST(TagStore, ItemsThatCannotTakeAWriteAreNotTaggable)
{
    QString why;
    const auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << qPrintable(why);
    const QString file = makeFile(*dir, QStringLiteral("locked.txt"));
    if (TagStore::support(file) == TagStore::Support::NoXattr)
        GTEST_SKIP() << "the filesystem of GRASSFIELD_TEST_TMP has no user extended attributes";
    // A FIFO takes no user attribute (EPERM): it is not offered.
    const QString fifo = dir->filePath(QStringLiteral("pipe"));
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    EXPECT_EQ(TagStore::support(fifo), TagStore::Support::NotRegular);
    QString error;
    EXPECT_FALSE(TagStore::writeRaw(fifo, "Red", &error));
    EXPECT_FALSE(error.isEmpty());
    // A read-only file: the write would be refused (skipped for root, which is not bound by permissions).
    if (::geteuid() != 0) {
        ASSERT_EQ(::chmod(QFile::encodeName(file).constData(), 0444), 0);
        EXPECT_EQ(TagStore::support(file), TagStore::Support::ReadOnly);
        EXPECT_FALSE(TagStore::writeRaw(file, "Red", &error));
        ASSERT_EQ(::chmod(QFile::encodeName(file).constData(), 0644), 0);
        EXPECT_EQ(TagStore::support(file), TagStore::Support::Supported);
    }
    // Reading still works on a read-only file: its tags show.
    EXPECT_TRUE(TagStore::read(file).isEmpty());
}
