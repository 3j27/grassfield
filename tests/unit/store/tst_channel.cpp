// Where the catalog comes from (ADR-0037 g "Where") and which URLs the Store may request (c).
#include "channel.h"

#include <gtest/gtest.h>

using namespace grassfield::store;

TEST(Channel, ThePrimaryServerOfGrassfieldConf)
{
    const auto c = channelFromConf("# Grassfield\nSigLevel = Required\nServer = https://packages.example.org/beta/$arch\n"
                                   "Server = https://mirror.example.net/beta/$arch\n");
    ASSERT_TRUE(c);
    EXPECT_EQ(c->name, QStringLiteral("beta"));
    EXPECT_EQ(c->base, QUrl(QStringLiteral("https://packages.example.org")));
    EXPECT_EQ(catalogUrl(*c), QUrl(QStringLiteral("https://packages.example.org/beta/x86_64/grassfield-catalog.v1.json")));
    EXPECT_EQ(signatureUrl(catalogUrl(*c)), QUrl(QStringLiteral("https://packages.example.org/beta/x86_64/grassfield-catalog.v1.json.sig")));
    EXPECT_EQ(iconUrl(*c, QString(64, u'a')), QUrl(QStringLiteral("https://packages.example.org/beta/x86_64/catalog/") + QString(64, u'a') + QStringLiteral(".png")));

    const auto path = channelFromConf("Server = https://example.org/grassfield/stable/$arch\n");
    ASSERT_TRUE(path);
    EXPECT_EQ(catalogUrl(*path), QUrl(QStringLiteral("https://example.org/grassfield/stable/x86_64/grassfield-catalog.v1.json")));
}

TEST(Channel, OtherShapesFallBackToTheBuildsBase)
{
    EXPECT_FALSE(channelFromConf(""));
    EXPECT_FALSE(channelFromConf("#Server = https://packages.example.org/stable/$arch\n"));
    EXPECT_FALSE(channelFromConf("Server = https://packages.example.org/custom/$arch\n"));        // a `custom` Server
    EXPECT_FALSE(channelFromConf("Server = http://packages.example.org/stable/$arch\n"));         // not https
    EXPECT_FALSE(channelFromConf("Server = https://user@packages.example.org/stable/$arch\n"));   // credentials
    EXPECT_FALSE(channelFromConf("Server = https://packages.example.org/stable/x86_64\n"));       // not pacman's $arch
    // Only the primary decides: a good mirror after a custom primary changes nothing.
    EXPECT_FALSE(channelFromConf("Server = file:///srv/repo/stable/$arch\nServer = https://packages.example.org/stable/$arch\n"));
}

TEST(Channel, ThePlaceholderFetchesNothing)
{
    const Channel placeholder = defaultChannel(QStringLiteral("https://packages.grassfield.invalid"));
    EXPECT_EQ(placeholder.name, QStringLiteral("stable"));
    EXPECT_FALSE(fetchable(placeholder));
    EXPECT_TRUE(fetchable(defaultChannel(QStringLiteral("https://packages.example.org/"))));
    EXPECT_FALSE(fetchable(defaultChannel(QStringLiteral("http://packages.example.org"))));
    EXPECT_FALSE(fetchable(defaultChannel(QString())));
}

TEST(Channel, RequestsAreHttpsOnly)
{
    EXPECT_TRUE(requestAllowed(QUrl(QStringLiteral("https://packages.example.org/x")), false));
    EXPECT_FALSE(requestAllowed(QUrl(QStringLiteral("http://packages.example.org/x")), false));
    EXPECT_FALSE(requestAllowed(QUrl(QStringLiteral("ftp://packages.example.org/x")), true));
    EXPECT_FALSE(requestAllowed(QUrl(QStringLiteral("file:///tmp/catalog.json")), false));
    EXPECT_TRUE(requestAllowed(QUrl(QStringLiteral("file:///tmp/catalog.json")), true)); // dev plumbing only
    EXPECT_FALSE(requestAllowed(QUrl(QStringLiteral("https://user:pw@packages.example.org/x")), false));
    EXPECT_FALSE(requestAllowed(QUrl(), true));
}

// The base this build was made with, read from the installed repository.conf (one KEY=value per line).
TEST(Channel, TheBuildsBase)
{
    EXPECT_EQ(buildBase("# a comment\nGRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_REPO_MIRRORS=\n"),
              QStringLiteral("https://packages.grassfield.site"));
    EXPECT_TRUE(fetchable(defaultChannel(buildBase("GRASSFIELD_REPO_BASE=https://packages.grassfield.site\n"))));
    EXPECT_EQ(buildBase("GRASSFIELD_REPO_BASE_PREVIOUS=https://old.example\n"), QString());
    EXPECT_EQ(buildBase(""), QString());
    EXPECT_FALSE(fetchable(defaultChannel(buildBase("GRASSFIELD_REPO_BASE=https://packages.grassfield.invalid\n"))));
}

// A build with a base but no signing key asks nothing of its host (ADR-0033 O11): there is no catalog it could verify.
TEST(Channel, TheBuildsKeyGatesTheFetch)
{
    const QByteArray shipped("GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_SIGNING_FINGERPRINT=\n");
    const QByteArray keyed("GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_SIGNING_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567\n");
    EXPECT_FALSE(buildHasKey(shipped));
    EXPECT_FALSE(buildHasKey("GRASSFIELD_SIGNING_FINGERPRINT=   \n"));
    EXPECT_FALSE(buildHasKey(QByteArray()));
    EXPECT_FALSE(buildHasKey("# GRASSFIELD_SIGNING_FINGERPRINT=0123\n"));
    EXPECT_TRUE(buildHasKey(keyed));
    EXPECT_FALSE(fetchable(buildChannel(shipped, "1.0.0")));      // base, no key: nothing is requested, the Store has nothing to show
    EXPECT_FALSE(fetchable(buildChannel(QByteArray(), QByteArray())));
    EXPECT_TRUE(fetchable(buildChannel(keyed, "1.0.0")));
    EXPECT_EQ(buildChannel(keyed, "1.0.0").base, QUrl(QStringLiteral("https://packages.grassfield.site")));
}

// ADR-0033 O15b: a build not set up follows the channel its VERSION allows. Only a plain X.Y.Z follows stable; a prerelease, and a
// missing, empty or malformed VERSION, follow beta (stable is empty until a plain version is published).
TEST(Channel, TheInstalledVersionDecidesTheDefaultChannel)
{
    EXPECT_EQ(releaseChannelOf("1.0.0\n"), QStringLiteral("stable"));
    EXPECT_EQ(releaseChannelOf("12.34.56"), QStringLiteral("stable"));
    EXPECT_EQ(releaseChannelOf("1.0.0-rc2\n"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("1.1.0-beta3"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf(QByteArray()), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("\n"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("unknown"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("1.0"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("1.0.0.1"), QStringLiteral("beta"));
    EXPECT_EQ(releaseChannelOf("1.0.0\n1.0.0"), QStringLiteral("beta"));
    const QByteArray keyed("GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_SIGNING_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567\n");
    EXPECT_EQ(buildChannel(keyed, "1.0.0-rc2").name, QStringLiteral("beta"));
    EXPECT_EQ(buildChannel(keyed, QByteArray()).name, QStringLiteral("beta"));
    EXPECT_EQ(buildChannel(keyed, "1.0.0").name, QStringLiteral("stable"));
    EXPECT_EQ(catalogUrl(buildChannel(keyed, "1.0.0-rc2")), QUrl(QStringLiteral("https://packages.grassfield.site/beta/x86_64/grassfield-catalog.v1.json")));
}
