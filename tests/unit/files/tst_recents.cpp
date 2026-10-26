// Unit tests for apps/files/src/recents.{h,cpp} (gtest): Recents of Grassfield Files read from recently-used.xbel
// (docs/specs/files.md "Views and selection", decision F-5). Built and run by scripts/dev/test.sh. The loader test only
// writes under GRASSFIELD_TEST_TMP, a directory inside the repository's .dev/ (set by scripts/dev/test.sh); it skips
// without it.
#include "recents.h"

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QTemporaryDir>
#include <QTimer>

#include <memory>

#include <gtest/gtest.h>

namespace
{
// The shape GTK writes (application times with microseconds, a mime type, several applications).
const char *kXbel = R"(<?xml version="1.0" encoding="UTF-8"?>
<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">
  <bookmark href="file:///home/u/old.txt" added="2026-01-01T10:00:00.000000Z" modified="2026-01-02T10:00:00.000000Z" visited="2026-01-02T10:00:00.000000Z">
    <info><metadata owner="http://freedesktop.org"><mime:mime-type type="text/plain"/>
      <bookmark:applications><bookmark:application name="Editor" exec="&apos;editor %u&apos;" modified="2026-01-03T10:00:00.123456Z" count="2"/></bookmark:applications>
    </metadata></info>
  </bookmark>
  <bookmark href="file:///home/u/Pictures/new%20shot.png" added="2026-10-26T09:00:00Z" modified="2026-10-26T09:00:00Z" visited="2026-10-26T09:30:00Z"/>
  <bookmark href="sftp://host/remote.txt" added="2026-10-26T09:00:00Z" modified="2026-10-26T09:00:00Z" visited="2026-10-26T09:00:00Z"/>
  <bookmark href="file:///home/u/old.txt" added="2025-01-01T10:00:00Z" modified="2025-01-01T10:00:00Z" visited="2025-01-01T10:00:00Z"/>
  <bookmark href="file:relative.txt" modified="2026-10-26T09:00:00Z"/>
  <bookmark href="file:///home/u/no-time.txt"/>
</xbel>
)";

std::unique_ptr<QTemporaryDir> sandbox()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/")))
        return nullptr;
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/recents-XXXXXX"));
    return dir->isValid() ? std::move(dir) : nullptr;
}

QCoreApplication &app()
{
    static int argc = 1;
    static char name[] = "tst_recents";
    static char *argv[] = {name, nullptr};
    if (!QCoreApplication::instance())
        new QCoreApplication(argc, argv);
    return *QCoreApplication::instance();
}
} // namespace

TEST(Recents, LocalFilesNewestFirstEachOnce)
{
    const QList<Recents::Entry> entries = Recents::parse(QByteArray(kXbel));
    ASSERT_EQ(entries.size(), 2) << "the sftp, relative and timeless entries are skipped, old.txt listed once";
    EXPECT_EQ(entries.at(0).path, QStringLiteral("/home/u/Pictures/new shot.png")) << "percent-decoded";
    EXPECT_EQ(entries.at(0).used, QDateTime::fromString(QStringLiteral("2026-10-26T09:30:00Z"), Qt::ISODate)) << "the visit is the latest use";
    EXPECT_EQ(entries.at(1).path, QStringLiteral("/home/u/old.txt"));
    EXPECT_EQ(entries.at(1).used.toUTC().date(), QDate(2026, 1, 3)) << "an application's later use counts, microseconds read";
}

TEST(Recents, BrokenDocumentsKeepWhatWasRead)
{
    QByteArray broken(kXbel);
    broken.truncate(broken.indexOf("sftp://"));
    const QList<Recents::Entry> entries = Recents::parse(broken);
    EXPECT_EQ(entries.size(), 2) << "the two complete bookmarks before the cut";
    EXPECT_TRUE(Recents::parse(QByteArray("not xml at all")).isEmpty());
    EXPECT_TRUE(Recents::parse(QByteArray()).isEmpty());
}

TEST(Recents, LocationAndFile)
{
    EXPECT_TRUE(Recents::isRecentsUrl(Recents::locationUrl()));
    EXPECT_FALSE(Recents::isRecentsUrl(QUrl::fromLocalFile(QStringLiteral("/tmp"))));
    qputenv("XDG_DATA_HOME", "/data/home");
    EXPECT_EQ(Recents::xbelPath(), QStringLiteral("/data/home/recently-used.xbel"));
    qputenv("XDG_DATA_HOME", "relative/path");
    EXPECT_EQ(Recents::xbelPath(), QDir::homePath() + QStringLiteral("/.local/share/recently-used.xbel")) << "a relative value is ignored";
    qunsetenv("XDG_DATA_HOME");
}

TEST(Recents, TheLoaderKeepsExistingFilesOnly)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    app();
    const QString present = dir->filePath(QStringLiteral("present.txt"));
    QFile(present).open(QIODevice::WriteOnly);
    QDir().mkpath(dir->filePath(QStringLiteral("folder")));
    const QString xbel = dir->filePath(QStringLiteral("recently-used.xbel"));
    QFile f(xbel);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    auto bookmark = [](const QString &path, const char *when) {
        return QStringLiteral("<bookmark href=\"%1\" modified=\"%2\" visited=\"%2\"/>\n").arg(QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded), QLatin1String(when)).toUtf8();
    };
    f.write("<?xml version=\"1.0\"?>\n<xbel version=\"1.0\">\n");
    f.write(bookmark(present, "2026-10-26T09:00:00Z"));
    f.write(bookmark(dir->filePath(QStringLiteral("gone.txt")), "2026-10-26T10:00:00Z"));
    f.write(bookmark(dir->filePath(QStringLiteral("folder")), "2026-10-26T11:00:00Z"));
    f.write("</xbel>\n");
    f.close();

    RecentsLoader loader(7, xbel);
    QStringList paths;
    QVariantList used;
    quint64 generation = 0;
    QObject::connect(&loader, &RecentsLoader::loaded, &loader, [&](quint64 g, const QStringList &p, const QVariantList &u) {
        generation = g;
        paths = p;
        used = u;
    }, Qt::DirectConnection);
    loader.start();
    ASSERT_TRUE(loader.wait(5000));
    EXPECT_EQ(generation, 7u);
    EXPECT_EQ(paths, QStringList{present}) << "missing files and folders are left out";
    ASSERT_EQ(used.size(), 1);
    EXPECT_EQ(used.at(0).toDateTime(), QDateTime::fromString(QStringLiteral("2026-10-26T09:00:00Z"), Qt::ISODate));
}
