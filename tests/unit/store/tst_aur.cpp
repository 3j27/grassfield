// The AUR's web service as the Store reads it (apps/store/src/aur.h; ADR-0037 c, e.6, ST7; spec SR7, SR11): RPC v5 answers
// parsed with bounds and every field checked, dependencies read, search terms, the three URLs, and the client through the dev
// plumbing's folder (tests/fixtures/store/aur: made-up packages in the AUR's own answer format) with its one-hour cache.
#include "aur.h"
#include "storetest.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QDateTime>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <utime.h>

using namespace grassfield::store;

namespace {

AurConfig fixtureConfig(const QString &cache)
{
    AurConfig c;
    c.base = QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur"));
    c.devPlumbing = true;
    c.cacheDir = cache;
    return c;
}

QStringList names(const QList<AurPackage> &packages)
{
    QStringList out;
    for (const AurPackage &p : packages)
        out.append(p.name);
    return out;
}

} // namespace

TEST(Aur, InfoAnswerReadWithItsBounds)
{
    const AurAnswer a = parseAurAnswer(storetest::readFixture(QStringLiteral("aur/info.json")), QStringLiteral("multiinfo"));
    ASSERT_TRUE(a.ok);
    // A name, a version or a package base the Store does not accept: that result is dropped, the others kept.
    ASSERT_EQ(names(a.packages), (QStringList{QStringLiteral("example-app-bin"), QStringLiteral("example-lib"), QStringLiteral("example-tool-git")}));
    const AurPackage &app = a.packages.at(0);
    EXPECT_EQ(app.version, QStringLiteral("2.4.1-1"));
    EXPECT_EQ(app.base, QStringLiteral("example-app-bin"));
    EXPECT_EQ(app.maintainer, QStringLiteral("alice"));
    EXPECT_FALSE(app.orphaned);
    EXPECT_EQ(app.votes, 120);
    EXPECT_DOUBLE_EQ(app.popularity, 1.53);
    EXPECT_FALSE(app.outOfDate.isValid());
    EXPECT_EQ(app.lastModified.toSecsSinceEpoch(), 1790000000);
    EXPECT_EQ(app.url, QStringLiteral("https://example.org/app"));
    EXPECT_EQ(app.licenses, QStringList{QStringLiteral("MIT")});
    EXPECT_EQ(app.depends, (QStringList{QStringLiteral("gtk3"), QStringLiteral("example-lib>=1.2")}));
    EXPECT_EQ(app.makeDepends, QStringList{QStringLiteral("cmake")});
    EXPECT_EQ(app.optDepends, QStringList{QStringLiteral("libnotify: desktop notifications")});
    EXPECT_FALSE(app.dependenciesUnread);

    const AurPackage &lib = a.packages.at(1);
    EXPECT_TRUE(lib.orphaned); // Maintainer null
    EXPECT_TRUE(lib.maintainer.isEmpty());

    // Third-party text made plain; an http homepage is not kept; the out-of-date flag's time read.
    const AurPackage &tool = a.packages.at(2);
    EXPECT_EQ(tool.version, QStringLiteral("1:r12.gabc1234-1"));
    EXPECT_EQ(tool.description, QStringLiteral("A tool from the development branch"));
    EXPECT_TRUE(tool.url.isEmpty());
    EXPECT_EQ(tool.outOfDate.toSecsSinceEpoch(), 1791000000);
    EXPECT_EQ(tool.checkDepends, QStringList{QStringLiteral("python-pytest")});
}

TEST(Aur, MalformedAnswersAreRefusedWhole)
{
    EXPECT_FALSE(parseAurAnswer("not json", QStringLiteral("multiinfo")).ok);
    EXPECT_FALSE(parseAurAnswer(R"({"version":4,"type":"multiinfo","results":[]})", QStringLiteral("multiinfo")).ok);
    EXPECT_FALSE(parseAurAnswer(R"({"version":5,"type":"search","results":[]})", QStringLiteral("multiinfo")).ok);
    EXPECT_FALSE(parseAurAnswer(R"({"version":5,"type":"multiinfo","results":{}})", QStringLiteral("multiinfo")).ok);
    EXPECT_FALSE(parseAurAnswer(QByteArray(512 * 1024 + 1, ' '), QStringLiteral("multiinfo")).ok);
    // A time beyond tomorrow is not one the AUR gave: not flagged.
    const AurAnswer future = parseAurAnswer(QStringLiteral(R"({"version":5,"type":"multiinfo","results":[{"Name":"a","PackageBase":"a",
        "Version":"1-1","OutOfDate":%1}]})").arg(QDateTime::currentSecsSinceEpoch() + 3 * 86400).toUtf8(), QStringLiteral("multiinfo"));
    ASSERT_TRUE(future.ok);
    EXPECT_FALSE(future.packages.at(0).outOfDate.isValid());
    const AurAnswer error = parseAurAnswer(R"({"version":5,"type":"error","error":"Too many package results.\u0007"})", QStringLiteral("search"));
    EXPECT_FALSE(error.ok);
    EXPECT_EQ(error.error, QStringLiteral("Too many package results."));
    const AurAnswer empty = parseAurAnswer(R"({"version":5,"type":"multiinfo","resultcount":0,"results":[]})", QStringLiteral("multiinfo"));
    EXPECT_TRUE(empty.ok);
    EXPECT_TRUE(empty.packages.isEmpty());
    // A dependency the Store does not read: the plan made from this answer is not complete.
    const AurAnswer odd = parseAurAnswer(R"({"version":5,"type":"multiinfo","results":[{"Name":"a","PackageBase":"a","Version":"1-1",
        "Depends":["glibc","not a name"]}]})", QStringLiteral("multiinfo"));
    ASSERT_TRUE(odd.ok);
    EXPECT_TRUE(odd.packages.at(0).dependenciesUnread);
    EXPECT_EQ(odd.packages.at(0).depends, QStringList{QStringLiteral("glibc")});
}

TEST(Aur, DependencyNames)
{
    EXPECT_EQ(dependencyName(QStringLiteral("gtk3")), QStringLiteral("gtk3"));
    EXPECT_EQ(dependencyName(QStringLiteral("qt6-base>=6.8")), QStringLiteral("qt6-base"));
    EXPECT_EQ(dependencyName(QStringLiteral("python<3.14")), QStringLiteral("python"));
    EXPECT_EQ(dependencyName(QStringLiteral("libfoo.so=2-64")), QStringLiteral("libfoo.so"));
    EXPECT_EQ(dependencyName(QStringLiteral("a>=1:2.0-1")), QStringLiteral("a")); // an epoch keeps its colon
    EXPECT_EQ(dependencyName(QStringLiteral("libnotify: desktop notifications")), QStringLiteral("libnotify"));
    for (const char *bad : {"", "Foo", "a b", ">=1", "a>=", "a>>1", "-a", "a=1 2"})
        EXPECT_TRUE(dependencyName(QString::fromUtf8(bad)).isEmpty()) << bad;
}

TEST(Aur, SearchTermsAndUrls)
{
    EXPECT_TRUE(isAurSearchTerm(QStringLiteral("ch")));
    EXPECT_TRUE(isAurSearchTerm(QStringLiteral("web browser")));
    for (const QString &bad : {QStringLiteral("c"), QStringLiteral(" c "), QStringLiteral("a/b"), QString(65, QLatin1Char('a')),
                               QStringLiteral("ab") + QChar(0x202e), QStringLiteral("ab\n")})
        EXPECT_FALSE(isAurSearchTerm(bad)) << bad.toStdString();

    const QUrl aur(QStringLiteral("https://aur.archlinux.org"));
    EXPECT_EQ(aurInfoUrl(aur, {QStringLiteral("yay"), QStringLiteral("example-lib")}).toString(),
              QStringLiteral("https://aur.archlinux.org/rpc/v5/info?arg[]=yay&arg[]=example-lib"));
    EXPECT_EQ(aurSearchUrl(aur, QStringLiteral("web browser?x")).toString(QUrl::FullyEncoded),
              QStringLiteral("https://aur.archlinux.org/rpc/v5/search/web%20browser%3Fx?by=name"));
    EXPECT_EQ(aurPkgbuildUrl(aur, QStringLiteral("example-app-bin")).toString(),
              QStringLiteral("https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=example-app-bin"));
}

// The client through the dev plumbing's folder: the names asked, in their order, those the AUR knows; cached for an hour.
TEST(Aur, InfoSearchAndBuildScriptWithTheirCache)
{
    QTemporaryDir cache;
    const AurConfig c = fixtureConfig(cache.path());
    const AurAnswer info = aurInfo(c, {QStringLiteral("example-lib"), QStringLiteral("nope"), QStringLiteral("-rf"), QStringLiteral("example-app-bin")});
    ASSERT_TRUE(info.ok);
    EXPECT_EQ(names(info.packages), (QStringList{QStringLiteral("example-lib"), QStringLiteral("example-app-bin")}));
    EXPECT_TRUE(QFileInfo(cache.filePath(QStringLiteral("info/example-lib.json"))).isFile());
    EXPECT_FALSE(QFileInfo(cache.filePath(QStringLiteral("info/nope.json"))).exists());

    // From the cache once the service is gone; an answer older than an hour is not used.
    AurConfig gone = c;
    gone.base = QUrl::fromLocalFile(cache.filePath(QStringLiteral("nowhere")));
    EXPECT_EQ(names(aurInfo(gone, {QStringLiteral("example-app-bin")}).packages), QStringList{QStringLiteral("example-app-bin")});
    const QByteArray old = cache.filePath(QStringLiteral("info/example-app-bin.json")).toUtf8();
    utimbuf times{QDateTime::currentSecsSinceEpoch() - 3700, QDateTime::currentSecsSinceEpoch() - 3700};
    ASSERT_EQ(utime(old.constData(), &times), 0);
    const AurAnswer stale = aurInfo(gone, {QStringLiteral("example-app-bin")});
    EXPECT_FALSE(stale.ok);
    EXPECT_TRUE(stale.packages.isEmpty());

    // search by name: the fixture's answer filtered by the term, the most voted first.
    EXPECT_EQ(names(aurSearch(c, QStringLiteral("example")).packages),
              (QStringList{QStringLiteral("example-app-bin"), QStringLiteral("example-tool-git"), QStringLiteral("example-lib")}));
    EXPECT_EQ(names(aurSearch(c, QStringLiteral("Tool")).packages), QStringList{QStringLiteral("example-tool-git")});
    EXPECT_FALSE(aurSearch(c, QStringLiteral("x")).ok);

    // The build script, plain: line feeds and tabs kept, the escape sequences' control characters gone.
    const std::optional<QString> pkgbuild = aurPkgbuild(c, QStringLiteral("example-app-bin"));
    ASSERT_TRUE(pkgbuild.has_value());
    EXPECT_TRUE(pkgbuild->startsWith(QLatin1String("# Maintainer: alice\npkgname=example-app-bin\n")));
    EXPECT_TRUE(pkgbuild->contains(QLatin1String("\tarch=('x86_64')")));
    EXPECT_TRUE(pkgbuild->contains(QLatin1String("[31mcolour[0m")));
    EXPECT_FALSE(pkgbuild->contains(QChar(0x1b)));
    EXPECT_FALSE(aurPkgbuild(c, QStringLiteral("no-such-base")).has_value());
    EXPECT_FALSE(aurPkgbuild(c, QStringLiteral("../info.json")).has_value());
}

// 4 MiB in all: the oldest answers go first.
TEST(Aur, CacheIsBounded)
{
    QTemporaryDir cache;
    QDir().mkpath(cache.filePath(QStringLiteral("search")));
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    for (int i = 0; i < 9; ++i) {
        const QString path = cache.filePath(QStringLiteral("search/old%1").arg(i));
        storetest::writeFile(path, QByteArray(512 * 1024, 'x'));
        utimbuf times{now - 600 + i, now - 600 + i};
        utime(path.toUtf8().constData(), &times);
    }
    const AurConfig c = fixtureConfig(cache.path());
    ASSERT_TRUE(aurInfo(c, {QStringLiteral("example-lib")}).ok);
    qint64 total = 0;
    for (const QFileInfo &f : QDir(cache.filePath(QStringLiteral("search"))).entryInfoList(QDir::Files))
        total += f.size();
    total += QFileInfo(cache.filePath(QStringLiteral("info/example-lib.json"))).size();
    EXPECT_LE(total, 4 * 1024 * 1024);
    EXPECT_FALSE(QFileInfo::exists(cache.filePath(QStringLiteral("search/old0"))));
    EXPECT_TRUE(QFileInfo::exists(cache.filePath(QStringLiteral("search/old8"))));
    EXPECT_TRUE(QFileInfo::exists(cache.filePath(QStringLiteral("info/example-lib.json"))));
}
