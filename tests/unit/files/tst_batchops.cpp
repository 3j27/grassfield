// Files' multi-step commands (BatchOps; review of PR #98): Rename N Items, Make Alias and New Folder with Selection are applied
// all together or not at all, revert as one step, and never replace anything. Real files under GRASSFIELD_TEST_TMP (a
// directory inside .dev/; skipped without it).
#include "batchops.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <memory>

#include <gtest/gtest.h>

#include <unistd.h>

using namespace BatchOps;

namespace
{
std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/batchops-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

void write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray read(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

bool present(const QString &path)
{
    return QFileInfo::exists(path) || QFileInfo(path).isSymLink();
}
} // namespace

TEST(BatchOps, RenamesApplyTogetherAndRevertAsOne)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    for (const char *n : {"a", "b", "c"})
        write(d + QLatin1Char('/') + QLatin1String(n), n);
    const Steps steps{{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/x1")},
                      {Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/x2")},
                      {Step::Kind::Rename, d + QStringLiteral("/c"), d + QStringLiteral("/x3")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(d + QStringLiteral("/x2")), QByteArray("b"));
    EXPECT_FALSE(present(d + QStringLiteral("/a")));
    // One revert puts all three back.
    ASSERT_TRUE(apply(inverse(steps), &f));
    for (const char *n : {"a", "b", "c"})
        EXPECT_EQ(read(d + QLatin1Char('/') + QLatin1String(n)), QByteArray(n));
    EXPECT_FALSE(present(d + QStringLiteral("/x1")));
    // And apply() again is the redo.
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(d + QStringLiteral("/x3")), QByteArray("c"));
}

TEST(BatchOps, AFailurePartWayPutsBackWhatWasDone)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    for (const char *n : {"a", "b", "c"})
        write(d + QLatin1Char('/') + QLatin1String(n), n);
    write(d + QStringLiteral("/taken"), "mine");
    // The third target exists: the first two renames are put back and nothing is replaced.
    const Steps steps{{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/x1")},
                      {Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/x2")},
                      {Step::Kind::Rename, d + QStringLiteral("/c"), d + QStringLiteral("/taken")}};
    Failure f;
    EXPECT_FALSE(apply(steps, &f));
    EXPECT_EQ(f.step, 2);
    EXPECT_EQ(f.path, d + QStringLiteral("/c"));
    EXPECT_EQ(f.error, EEXIST);
    for (const char *n : {"a", "b", "c"})
        EXPECT_EQ(read(d + QLatin1Char('/') + QLatin1String(n)), QByteArray(n)) << n;
    EXPECT_FALSE(present(d + QStringLiteral("/x1")));
    EXPECT_FALSE(present(d + QStringLiteral("/x2")));
    EXPECT_EQ(read(d + QStringLiteral("/taken")), QByteArray("mine")) << "never replaced";
    // A source that is gone fails the same way.
    EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/y1")}, {Step::Kind::Rename, d + QStringLiteral("/gone"), d + QStringLiteral("/y2")}}, &f));
    EXPECT_EQ(f.step, 1);
    EXPECT_EQ(read(d + QStringLiteral("/a")), QByteArray("a"));
}

TEST(BatchOps, AliasesAreLinksUndoneOnlyWhileTheyStillPointThere)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/report.txt"), "r");
    write(d + QStringLiteral("/other.txt"), "o");
    const Steps steps{{Step::Kind::Link, d + QStringLiteral("/report.txt"), d + QStringLiteral("/report.txt alias")},
                      {Step::Kind::Link, d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(QFileInfo(d + QStringLiteral("/report.txt alias")).symLinkTarget(), d + QStringLiteral("/report.txt"));
    // A name that exists is never replaced: the whole command fails, the first link is removed again.
    EXPECT_FALSE(apply({{Step::Kind::Link, d + QStringLiteral("/report.txt"), d + QStringLiteral("/third")},
                        {Step::Kind::Link, d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")}}, &f));
    EXPECT_EQ(f.step, 1);
    EXPECT_FALSE(present(d + QStringLiteral("/third")));
    // The user replaced one alias by a file of the same name: undo stops, and leaves everything in place.
    ASSERT_TRUE(QFile::remove(d + QStringLiteral("/other.txt alias")));
    write(d + QStringLiteral("/other.txt alias"), "the user's own file");
    EXPECT_FALSE(apply(inverse(steps), &f));
    EXPECT_EQ(read(d + QStringLiteral("/other.txt alias")), QByteArray("the user's own file"));
    EXPECT_TRUE(QFileInfo(d + QStringLiteral("/report.txt alias")).isSymLink()) << "the first alias is still there: the revert failed as a whole";
    // Once the alias is the user's again as it was, undo works.
    ASSERT_TRUE(QFile::remove(d + QStringLiteral("/other.txt alias")));
    ASSERT_TRUE(QFile::link(d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")));
    ASSERT_TRUE(apply(inverse(steps), &f));
    EXPECT_FALSE(present(d + QStringLiteral("/report.txt alias")));
    EXPECT_FALSE(present(d + QStringLiteral("/other.txt alias")));
    EXPECT_EQ(read(d + QStringLiteral("/report.txt")), QByteArray("r")) << "the originals are never touched";
}

TEST(BatchOps, ANewFolderWithItemsIsOneCommand)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/a.txt"), "a");
    write(d + QStringLiteral("/b.txt"), "b");
    const QString folder = d + QStringLiteral("/New Folder With Items");
    const Steps steps{{Step::Kind::Mkdir, QString(), folder},
                      {Step::Kind::Rename, d + QStringLiteral("/a.txt"), folder + QStringLiteral("/a.txt")},
                      {Step::Kind::Rename, d + QStringLiteral("/b.txt"), folder + QStringLiteral("/b.txt")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(folder + QStringLiteral("/b.txt")), QByteArray("b"));
    // One undo: the items out, then the folder removed.
    ASSERT_TRUE(apply(inverse(steps), &f));
    EXPECT_EQ(read(d + QStringLiteral("/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d + QStringLiteral("/b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(folder));
    ASSERT_TRUE(apply(steps, &f)) << "redo";
    // The user put something else in the folder: undo takes the items out but never removes a folder that is not empty,
    // and puts everything back as it was.
    write(folder + QStringLiteral("/mine.txt"), "m");
    EXPECT_FALSE(apply(inverse(steps), &f));
    EXPECT_EQ(f.path, folder);
    EXPECT_EQ(f.error, ENOTEMPTY);
    EXPECT_EQ(read(folder + QStringLiteral("/a.txt")), QByteArray("a")) << "the items are back in the folder";
    EXPECT_EQ(read(folder + QStringLiteral("/mine.txt")), QByteArray("m"));
    // A name taken stops the command before anything moves.
    ASSERT_TRUE(QDir(folder).removeRecursively());
    write(d + QStringLiteral("/a.txt"), "a");
    write(d + QStringLiteral("/b.txt"), "b");
    write(folder, "a file in the way");
    EXPECT_FALSE(apply(steps, &f));
    EXPECT_EQ(f.step, 0);
    EXPECT_EQ(read(d + QStringLiteral("/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(folder), QByteArray("a file in the way"));
}
