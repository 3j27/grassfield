// Unit tests for apps/files/src/filelogic.{h,cpp} (gtest). Built and run by scripts/dev/test.sh.
#include "filelogic.h"

#include <QCollator>
#include <QSet>

#include <gtest/gtest.h>

using namespace FileLogic;

namespace
{
QCollator naturalCollator()
{
    // The C locale collator has no numeric mode; the app also falls back to English for it.
    QCollator c(QLocale(QLocale::English, QLocale::UnitedStates));
    c.setNumericMode(true);
    c.setCaseSensitivity(Qt::CaseInsensitive);
    return c;
}

SortEntry file(const QString &name, qint64 size = 0, const QString &kind = QStringLiteral("Text"), const QDateTime &modified = {})
{
    SortEntry e;
    e.name = name;
    e.size = size;
    e.kind = kind;
    e.modified = modified;
    return e;
}

SortEntry folder(const QString &name)
{
    SortEntry e;
    e.name = name;
    e.isDir = true;
    e.kind = QStringLiteral("Folder");
    return e;
}

QStringList labels(const QList<Segment> &segments)
{
    QStringList out;
    for (const Segment &s : segments)
        out << s.label;
    return out;
}

QStringList urls(const QList<Segment> &segments)
{
    QStringList out;
    for (const Segment &s : segments)
        out << s.url.toString();
    return out;
}
} // namespace

TEST(SortKeys, NameIsNaturalAndCaseInsensitive)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(file("file2"), file("file10"), SortKey::Name, false, false, c), 0);
    EXPECT_LT(compareEntries(file("apple"), file("Banana"), SortKey::Name, false, false, c), 0);
    EXPECT_GT(compareEntries(file("apple"), file("Banana"), SortKey::Name, true, false, c), 0);
}

TEST(SortKeys, FoldersFirstInBothDirections)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, false, true, c), 0);
    EXPECT_LT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, true, true, c), 0);
    // Without the option folders sort with files.
    EXPECT_GT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, false, false, c), 0);
}

TEST(SortKeys, SizeDateKindWithNameTieBreak)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(file("b", 10), file("a", 20), SortKey::Size, false, false, c), 0);
    EXPECT_GT(compareEntries(file("b", 10), file("a", 20), SortKey::Size, true, false, c), 0);
    // Equal size: name ascending even when descending.
    EXPECT_LT(compareEntries(file("a", 10), file("b", 10), SortKey::Size, true, false, c), 0);

    const QDateTime older(QDate(2026, 1, 1), QTime(10, 0));
    const QDateTime newer(QDate(2026, 6, 1), QTime(10, 0));
    EXPECT_LT(compareEntries(file("x", 0, "Text", older), file("y", 0, "Text", newer), SortKey::Date, false, false, c), 0);
    EXPECT_LT(compareEntries(file("y", 0, "Text", newer), file("x", 0, "Text", older), SortKey::Date, true, false, c), 0);

    EXPECT_LT(compareEntries(file("z", 0, "Image"), file("a", 0, "Text"), SortKey::Kind, false, false, c), 0);
    EXPECT_LT(compareEntries(file("a", 0, "Text"), file("b", 0, "Text"), SortKey::Kind, false, false, c), 0);
}

TEST(SortKeys, TotalOrderForCaseVariants)
{
    const QCollator c = naturalCollator();
    const int ab = compareEntries(file("Readme"), file("readme"), SortKey::Name, false, false, c);
    const int ba = compareEntries(file("readme"), file("Readme"), SortKey::Name, false, false, c);
    EXPECT_NE(ab, 0);
    EXPECT_EQ(ab < 0, ba > 0);
}

TEST(SortKeys, DefaultDirections)
{
    EXPECT_FALSE(defaultDescending(SortKey::Name));
    EXPECT_FALSE(defaultDescending(SortKey::Kind));
    EXPECT_TRUE(defaultDescending(SortKey::Date));
    EXPECT_TRUE(defaultDescending(SortKey::Size));
}

TEST(SizeFormat, Bytes)
{
    const QLocale c = QLocale::c();
    EXPECT_EQ(formatSize(0, c), "Zero bytes");
    EXPECT_EQ(formatSize(1, c), "1 byte");
    EXPECT_EQ(formatSize(999, c), "999 bytes");
    EXPECT_EQ(formatSize(-1, c), "--");
}

TEST(SizeFormat, DecimalUnits)
{
    const QLocale c = QLocale::c();
    EXPECT_EQ(formatSize(1000, c), "1 KB");
    EXPECT_EQ(formatSize(1499, c), "1 KB");
    EXPECT_EQ(formatSize(1500, c), "2 KB");
    EXPECT_EQ(formatSize(12345, c), "12 KB");
    EXPECT_EQ(formatSize(999499, c), "999 KB");
    EXPECT_EQ(formatSize(999500, c), "1 MB");
    EXPECT_EQ(formatSize(1234567, c), "1.23 MB");
    EXPECT_EQ(formatSize(1200000, c), "1.2 MB");
    EXPECT_EQ(formatSize(12345678, c), "12.3 MB");
    EXPECT_EQ(formatSize(123456789, c), "123 MB");
    EXPECT_EQ(formatSize(465463709696LL, c), "465 GB");
    EXPECT_EQ(formatSize(2150000000000LL, c), "2.15 TB");
}

TEST(SizeFormat, LocaleDecimalSeparator)
{
    EXPECT_EQ(formatSize(1234567, QLocale(QLocale::French, QLocale::France)), "1,23 MB");
}

TEST(DateFormat, RelativeDays)
{
    const QLocale c = QLocale::c();
    const QDateTime now(QDate(2026, 10, 17), QTime(15, 0));
    EXPECT_EQ(formatDate(QDateTime(QDate(2026, 10, 17), QTime(9, 5)), now, c), "Today at " + c.toString(QTime(9, 5), QLocale::ShortFormat));
    EXPECT_EQ(formatDate(QDateTime(QDate(2026, 10, 16), QTime(23, 59)), now, c),
              "Yesterday at " + c.toString(QTime(23, 59), QLocale::ShortFormat));
    const QDateTime old(QDate(2025, 3, 2), QTime(8, 30));
    EXPECT_EQ(formatDate(old, now, c), c.toString(old.date(), QLocale::ShortFormat) + " at " + c.toString(old.time(), QLocale::ShortFormat));
    EXPECT_EQ(formatDate(QDateTime(), now, c), "--");
}

TEST(PathSegments, InsideHome)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/home/ana/Documents/Work"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(s), QStringList({"ana", "Documents", "Work"}));
    EXPECT_EQ(urls(s), QStringList({"file:///home/ana", "file:///home/ana/Documents", "file:///home/ana/Documents/Work"}));
}

TEST(PathSegments, HomeItselfAndTrailingSlash)
{
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/home/ana/"), "/home/ana", "Computer", "Trash")), QStringList({"ana"}));
    // A sibling whose name starts like the home folder is not inside it.
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/home/anab"), "/home/ana", "Computer", "Trash")),
              QStringList({"Computer", "home", "anab"}));
}

TEST(PathSegments, OutsideHomeStartsAtRoot)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/usr/share"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(s), QStringList({"Computer", "usr", "share"}));
    EXPECT_EQ(urls(s), QStringList({"file:///", "file:///usr", "file:///usr/share"}));
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/"), "/home/ana", "Computer", "Trash")), QStringList({"Computer"}));
}

TEST(PathSegments, TrashAndOtherSchemes)
{
    EXPECT_EQ(labels(pathSegments(QUrl("trash:/"), "/home/ana", "Computer", "Trash")), QStringList({"Trash"}));
    const QList<Segment> t = pathSegments(QUrl("trash:/0-old/sub"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(t), QStringList({"Trash", "0-old", "sub"}));
    EXPECT_EQ(urls(t), QStringList({"trash:/", "trash:/0-old", "trash:/0-old/sub"}));
    EXPECT_EQ(labels(pathSegments(QUrl("ftp://host/pub/x"), "/home/ana", "Computer", "Trash")), QStringList({"host", "pub", "x"}));
}

TEST(PathSegments, SpecialCharactersRoundTrip)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/home/ana/a b#c%d"), "/home/ana", "Computer", "Trash");
    ASSERT_EQ(s.size(), 2);
    EXPECT_EQ(s[1].label, "a b#c%d");
    EXPECT_EQ(s[1].url.toLocalFile(), "/home/ana/a b#c%d");
}

TEST(FileNames, Validity)
{
    EXPECT_TRUE(isValidFileName("report.txt"));
    EXPECT_TRUE(isValidFileName(" spaced "));
    EXPECT_TRUE(isValidFileName(".hidden"));
    EXPECT_FALSE(isValidFileName(""));
    EXPECT_FALSE(isValidFileName("."));
    EXPECT_FALSE(isValidFileName(".."));
    EXPECT_FALSE(isValidFileName("a/b"));
    EXPECT_FALSE(isValidFileName(QString("a") + QChar(0) + "b"));
    EXPECT_TRUE(isValidFileName(QString(255, 'x')));
    EXPECT_FALSE(isValidFileName(QString(256, 'x')));
    // 128 two-byte characters = 256 bytes.
    EXPECT_FALSE(isValidFileName(QString(128, QChar(0x00E9))));
}

TEST(FileNames, BaseNameLength)
{
    EXPECT_EQ(baseNameLength("report.txt", false), 6);
    EXPECT_EQ(baseNameLength("archive.tar.gz", false), 11);
    EXPECT_EQ(baseNameLength("README", false), 6);
    EXPECT_EQ(baseNameLength(".bashrc", false), 7);
    EXPECT_EQ(baseNameLength(".config.old", false), 7);
    EXPECT_EQ(baseNameLength("photos.2026", true), 11);
}

TEST(FileNames, UniqueAndDuplicateNames)
{
    QSet<QString> taken{"untitled folder", "untitled folder 2", "a copy.txt"};
    const auto exists = [&taken](const QString &n) { return taken.contains(n); };
    EXPECT_EQ(uniqueName("untitled folder", exists), "untitled folder 3");
    EXPECT_EQ(uniqueName("fresh", exists), "fresh");
    EXPECT_EQ(duplicateName("a.txt", false, "copy", exists), "a copy 2.txt");
    EXPECT_EQ(duplicateName("b.txt", false, "copy", exists), "b copy.txt");
    EXPECT_EQ(duplicateName("photos.2026", true, "copy", exists), "photos.2026 copy");
    EXPECT_EQ(duplicateName(".bashrc", false, "copy", exists), ".bashrc copy");
}

TEST(UnicodeNames, CanonicallyEquivalentNamesAreTheSameName)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    EXPECT_NE(nfc, nfd);
    EXPECT_TRUE(sameName(nfc, nfd));
    EXPECT_TRUE(sameName(nfc, nfc));
    EXPECT_FALSE(sameName(nfc, QStringLiteral("Resume.txt")));
    EXPECT_FALSE(sameName(nfc, nfc.toUpper()));
}

TEST(UnicodeNames, FilterIgnoresCaseAndAccentsInBothForms)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    for (const QString &name : {nfc, nfd}) {
        EXPECT_TRUE(nameMatchesFilter(name, QStringLiteral("resume")));
        EXPECT_TRUE(nameMatchesFilter(name, QStringLiteral("RESUME")));
        EXPECT_TRUE(nameMatchesFilter(name, nfc.left(3)));
        EXPECT_TRUE(nameMatchesFilter(name, nfd.left(4)));
        EXPECT_FALSE(nameMatchesFilter(name, QStringLiteral("resumes")));
    }
    // Names with quotes and backslashes are plain text for the filter.
    EXPECT_TRUE(nameMatchesFilter(QStringLiteral("a\"b\\c"), QStringLiteral("\"b\\")));
}

TEST(UnicodeNames, EquivalentNameFindsOnlyTheTwin)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    EXPECT_EQ(equivalentName({QStringLiteral("a.txt"), nfd}, nfc), nfd);
    EXPECT_TRUE(equivalentName({QStringLiteral("a.txt"), nfc}, nfc).isEmpty()); // the same string is a plain conflict
    EXPECT_TRUE(equivalentName({}, nfc).isEmpty());
    EXPECT_TRUE(equivalentName({QStringLiteral("Resume.txt")}, nfc).isEmpty());
}

TEST(UnicodeNames, TrashInfoGivesTheOriginalPath)
{
    EXPECT_EQ(trashInfoOriginalPath("[Trash Info]\nPath=/home/u/R%C3%A9sum%C3%A9.txt\nDeletionDate=2026-10-24T10:00:00\n"), QString::fromUtf8("/home/u/R\xc3\xa9sum\xc3\xa9.txt"));
    EXPECT_TRUE(trashInfoOriginalPath("[Trash Info]\nPath=relative/name\n").isEmpty());
    EXPECT_TRUE(trashInfoOriginalPath("[Other]\nPath=/x\n").isEmpty());
    EXPECT_TRUE(trashInfoOriginalPath("").isEmpty());
}

TEST(UnicodeNames, DisplayNameWritesOutBidiControlsAndBreaks)
{
    EXPECT_EQ(displayName(QString::fromUtf8("evil\xe2\x80\xaa" "fdp.exe")), QStringLiteral("evil<U+202A>fdp.exe"));
    EXPECT_EQ(displayName(QString(QChar(0x202E))), QStringLiteral("<U+202E>"));
    EXPECT_EQ(displayName(QStringLiteral("a") + QChar(0x2028) + QStringLiteral("b") + QChar(0x2029)), QStringLiteral("a<U+2028>b<U+2029>"));
    EXPECT_EQ(displayName(QString(QChar(0x2066)) + QChar(0x2069)), QStringLiteral("<U+2066><U+2069>"));
    EXPECT_EQ(displayName(QStringLiteral("two\r\nlines")), QString(QStringLiteral("two") + QChar(0x23CE) + QStringLiteral("lines")));
    EXPECT_EQ(displayName(QString(QChar(0x200E)) + QStringLiteral("kept")), QString(QChar(0x200E)) + QStringLiteral("kept"));
    EXPECT_EQ(displayName(QStringLiteral("say \"hi\" \\ there")), QStringLiteral("say \"hi\" \\ there"));
}

TEST(NetworkPlace, HidesTheAppleDevicesEntry)
{
    // kio-extras remoteview entries in remote:/ (afc-network.desktop links to afc:/).
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/afc-network"), QUrl("afc:/")));
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/afc-network.desktop"), QUrl()));
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/something"), QUrl("afc:/")));
    EXPECT_FALSE(hiddenNetworkEntry(QUrl("remote:/smb-network"), QUrl("smb://")));
    EXPECT_FALSE(hiddenNetworkEntry(QUrl("remote:/mtp-network"), QUrl("mtp:/")));
    // Only the Network place: a local file of that name stays visible.
    EXPECT_FALSE(hiddenNetworkEntry(QUrl::fromLocalFile("/tmp/afc-network.desktop"), QUrl::fromLocalFile("/tmp/afc-network.desktop")));
}
