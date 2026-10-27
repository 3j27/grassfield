// The Store's requests (ADR-0037 c): https only, file:// only through dev plumbing, a size cap that drops (never
// truncates). The https path itself needs a server: its rules are requestAllowed's (tst_channel.cpp); here file:// in
// dev runs the same code with the caps.
#include "fetch.h"
#include "storetest.h"

#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

TEST(Fetch, RefusesWhatIsNotHttps)
{
    storetest::ensureApp();
    EXPECT_EQ(fetch(QUrl(QStringLiteral("http://example.org/x")), {}).status, FetchResult::Status::Refused);
    EXPECT_EQ(fetch(QUrl(QStringLiteral("file:///etc/hostname")), {}).status, FetchResult::Status::Refused);
    EXPECT_EQ(fetch(QUrl(QStringLiteral("ftp://example.org/x")), {}, {}, true).status, FetchResult::Status::Refused);
}

TEST(Fetch, DevPlumbingReadsAFileWithinItsCap)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("catalog.json")), QByteArray(1000, 'x'));
    const QUrl url = QUrl::fromLocalFile(dir.filePath(QStringLiteral("catalog.json")));
    FetchResult r = fetch(url, {}, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    EXPECT_EQ(r.body.size(), 1000);

    FetchLimits small;
    small.maxBytes = 999;
    r = fetch(url, small, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());

    r = fetch(QUrl::fromLocalFile(dir.filePath(QStringLiteral("missing.json"))), {}, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::Failed);
}

TEST(Fetch, DownloadToAFile)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("package")), QByteArray(5000, 'p'));
    const QUrl url = QUrl::fromLocalFile(dir.filePath(QStringLiteral("package")));
    const QString out = dir.filePath(QStringLiteral("out"));
    ASSERT_TRUE(downloadTo(url, out, {}, true));
    QFile f(out);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(f.readAll(), QByteArray(5000, 'p'));
    f.close();
    FetchLimits small;
    small.maxBytes = 4999;
    EXPECT_FALSE(downloadTo(url, out, small, true));
    EXPECT_FALSE(QFile::exists(out)); // the earlier copy is gone too: a failed download leaves nothing
    EXPECT_FALSE(downloadTo(QUrl(QStringLiteral("http://example.org/p")), out, {}));
}

