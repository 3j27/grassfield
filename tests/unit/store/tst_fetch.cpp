// The Store's requests (ADR-0037 c): https only, file:// only through dev plumbing, a size cap that drops (never
// truncates). The https path itself needs a server: its rules are requestAllowed's (tst_channel.cpp); here file:// in
// dev runs the same code with the caps.
#include "fetch.h"
#include "storetest.h"

#include <QFile>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
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

TEST(Fetch, TheRequest)
{
    const QNetworkRequest r = storeRequest(QUrl(QStringLiteral("https://example.org/x")), FetchLimits{1024, 7000}, "\"etag-1\"");
    EXPECT_EQ(r.rawHeader("User-Agent"), QByteArray("Grassfield-Store/1"));
    EXPECT_FALSE(r.hasRawHeader("Referer"));
    EXPECT_FALSE(r.hasRawHeader("Cookie"));
    EXPECT_EQ(r.rawHeader("If-None-Match"), QByteArray("\"etag-1\""));
    EXPECT_EQ(r.attribute(QNetworkRequest::CookieLoadControlAttribute).toInt(), int(QNetworkRequest::Manual));
    EXPECT_EQ(r.attribute(QNetworkRequest::CookieSaveControlAttribute).toInt(), int(QNetworkRequest::Manual));
    EXPECT_EQ(r.attribute(QNetworkRequest::CacheLoadControlAttribute).toInt(), int(QNetworkRequest::AlwaysNetwork));
    EXPECT_FALSE(r.attribute(QNetworkRequest::CacheSaveControlAttribute).toBool());
    EXPECT_EQ(r.attribute(QNetworkRequest::RedirectPolicyAttribute).toInt(), int(QNetworkRequest::UserVerifiedRedirectPolicy));
    EXPECT_EQ(r.maximumRedirectsAllowed(), 5);
    EXPECT_EQ(r.transferTimeout(), 7000);
    EXPECT_FALSE(storeRequest(QUrl(QStringLiteral("https://example.org/x")), {}).hasRawHeader("If-None-Match"));
}

// A real https server in the container of tests/integration/store_catalog.sh (STORE_TEST_HTTPS, its throwaway
// certificate trusted there): redirects, cookies and the size cap as the network does them.
TEST(Fetch, RealHttpsServer)
{
    const QString base = qEnvironmentVariable("STORE_TEST_HTTPS");
    if (base.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    storetest::ensureApp();
    auto get = [&](const QString &path, qint64 maxBytes = 1024 * 1024) {
        return fetch(QUrl(base + path), FetchLimits{maxBytes, 10000});
    };
    // A cookie set on the way is never sent back, nor a Referer; the User-Agent is the Store's.
    FetchResult r = get(QStringLiteral("/cookie"));
    ASSERT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    const QJsonObject headers = QJsonDocument::fromJson(r.body).object();
    EXPECT_FALSE(headers.contains(QStringLiteral("cookie"))) << r.body.toStdString();
    EXPECT_FALSE(headers.contains(QStringLiteral("referer"))) << r.body.toStdString();
    EXPECT_EQ(headers.value(QStringLiteral("user-agent")).toString(), QStringLiteral("Grassfield-Store/1"));
    // A redirect to http is refused; five redirects are followed, a sixth is not.
    EXPECT_EQ(get(QStringLiteral("/to-http")).status, FetchResult::Status::Refused);
    r = get(QStringLiteral("/chain/5"));
    EXPECT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    EXPECT_EQ(r.body, QByteArray("end"));
    EXPECT_EQ(get(QStringLiteral("/chain/6")).status, FetchResult::Status::Failed);
    // Over the cap: dropped, never truncated and used, whether the length is announced or not.
    r = get(QStringLiteral("/big"), 1000);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());
    r = get(QStringLiteral("/big-chunked"), 1000);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());

    // A plan's HEADs (the integrator's review of ff2fd83): twelve files that each take a second to answer, asked at once, in
    // well under twelve seconds; one gone (404) drops the others still running; one that never answers is 0 at the set's
    // deadline.
    QList<QUrl> slow;
    for (int i = 0; i < 12; ++i)
        slow.append(QUrl(base + QStringLiteral("/slow/%1").arg(i)));
    QElapsedTimer clock;
    clock.start();
    EXPECT_EQ(headStatuses(slow, 10000, 20000), QList<int>(12, 200));
    EXPECT_LT(clock.elapsed(), 6000);
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/slow/a")), QUrl(base + QStringLiteral("/gone"))}, 10000, 20000), (QList<int>{0, 404}));
    clock.restart();
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/hang"))}, 10000, 1500), QList<int>{0});
    EXPECT_LT(clock.elapsed(), 4000);
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/to-http"))}, 10000, 5000), QList<int>{-1}) << "a redirect to http";
}

// A plan's HEADs through dev plumbing (file://): a file there answers 200, a missing one 404 and drops the rest; file://
// without dev plumbing, or http, is not requested (-1).
TEST(Fetch, HeadStatusesThroughDevPlumbing)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("a.pkg")), "a");
    storetest::writeFile(dir.filePath(QStringLiteral("c.pkg")), "c");
    const auto file = [&dir](const char *name) { return QUrl::fromLocalFile(dir.filePath(QLatin1String(name))); };
    EXPECT_EQ(headStatuses({file("a.pkg"), file("c.pkg")}, 1000, 1000, true), (QList<int>{200, 200}));
    EXPECT_EQ(headStatuses({file("a.pkg"), file("b.pkg"), file("c.pkg")}, 1000, 1000, true), (QList<int>{200, 404, 0}));
    EXPECT_EQ(headStatuses({QUrl(QStringLiteral("http://example.org/a.pkg")), file("a.pkg")}, 1000, 1000), (QList<int>{-1, -1}));
    EXPECT_TRUE(headStatuses({}, 1000, 1000).isEmpty());
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

