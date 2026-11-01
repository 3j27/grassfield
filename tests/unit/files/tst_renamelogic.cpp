// Rename N Items (RenameLogic): Replace Text, Add Text, Format, and the checks before KIO renames anything.
#include "renamelogic.h"

#include <gtest/gtest.h>

using namespace RenameLogic;

namespace
{
const QDateTime kNow(QDate(2026, 11, 1), QTime(10, 5, 9));
}

TEST(RenameItems, ReplaceTextInTheNameOnly)
{
    Options o;
    o.mode = Mode::Replace;
    o.find = QStringLiteral("IMG");
    o.replaceWith = QStringLiteral("Trip");
    EXPECT_EQ(newNames({QStringLiteral("IMG_01.jpg"), QStringLiteral("img_02.jpg"), QStringLiteral("IMG IMG")}, {false, false, true}, o, kNow),
              (QStringList{QStringLiteral("Trip_01.jpg"), QStringLiteral("img_02.jpg"), QStringLiteral("Trip Trip")}))
        << "case-sensitive, every occurrence, a folder's whole name";
    o.find = QStringLiteral("jpg");
    EXPECT_EQ(newNames({QStringLiteral("jpg.jpg")}, {false}, o, kNow), QStringList{QStringLiteral("Trip.jpg")}) << "the extension stays";
    o.find.clear();
    EXPECT_EQ(newNames({QStringLiteral("a.txt")}, {false}, o, kNow), QStringList{QStringLiteral("a.txt")});
}

TEST(RenameItems, AddTextBeforeOrAfterTheName)
{
    Options o;
    o.mode = Mode::Add;
    o.addText = QStringLiteral(" (old)");
    EXPECT_EQ(newNames({QStringLiteral("report.pdf"), QStringLiteral("Folder.v2")}, {false, true}, o, kNow),
              (QStringList{QStringLiteral("report (old).pdf"), QStringLiteral("Folder.v2 (old)")}));
    o.where = Where::BeforeName;
    o.addText = QStringLiteral("2026 ");
    EXPECT_EQ(newNames({QStringLiteral(".bashrc")}, {false}, o, kNow), QStringList{QStringLiteral("2026 .bashrc")});
}

TEST(RenameItems, FormatWithIndexCounterOrDate)
{
    Options o;
    o.mode = Mode::Format;
    o.customFormat = QStringLiteral("Photo");
    o.startAt = 3;
    const QStringList names = {QStringLiteral("a.jpg"), QStringLiteral("b.png")};
    EXPECT_EQ(newNames(names, {false, false}, o, kNow), (QStringList{QStringLiteral("Photo 3.jpg"), QStringLiteral("Photo 4.png")}));
    o.format = Format::NameAndCounter;
    o.startAt = 1;
    EXPECT_EQ(newNames(names, {false, false}, o, kNow), (QStringList{QStringLiteral("Photo 00001.jpg"), QStringLiteral("Photo 00002.png")}));
    o.format = Format::NameAndDate;
    EXPECT_EQ(newNames(names, {false, false}, o, kNow),
              (QStringList{QStringLiteral("Photo 2026-11-01 at 10.05.09.jpg"), QStringLiteral("Photo 2026-11-01 at 10.05.09 2.png")}))
        << "the same date: the index after the first";
    o.format = Format::NameAndIndex;
    o.where = Where::BeforeName;
    EXPECT_EQ(newNames({QStringLiteral("x")}, {true}, o, kNow), QStringList{QStringLiteral("1 Photo")});
}

TEST(RenameItems, ChecksBeforeRenaming)
{
    const QStringList folders = {QStringLiteral("/d"), QStringLiteral("/d")};
    QString name;
    EXPECT_EQ(check({QStringLiteral("a"), QStringLiteral("b")}, {QStringLiteral("c"), QStringLiteral("d")}, folders, &name), Problem::None);
    EXPECT_EQ(check({QStringLiteral("a"), QStringLiteral("b")}, {QStringLiteral("c"), QStringLiteral("c")}, folders, &name), Problem::Duplicate);
    EXPECT_EQ(name, QStringLiteral("c"));
    EXPECT_EQ(check({QStringLiteral("a"), QStringLiteral("b")}, {QStringLiteral("c"), QStringLiteral("c")}, {QStringLiteral("/d"), QStringLiteral("/e")}),
              Problem::None) << "the same name in two folders (a search)";
    EXPECT_EQ(check({QStringLiteral("a"), QStringLiteral("b")}, {QStringLiteral("b"), QStringLiteral("x")}, folders, &name), Problem::TakenInBatch);
    EXPECT_EQ(check({QStringLiteral("a")}, {QStringLiteral("a/b")}, {QStringLiteral("/d")}), Problem::InvalidName);
    EXPECT_EQ(check({QStringLiteral("a")}, {QString()}, {QStringLiteral("/d")}), Problem::InvalidName);
    EXPECT_EQ(check({QStringLiteral("a")}, {QStringLiteral("a")}, {QStringLiteral("/d")}), Problem::NothingChanges);
}
