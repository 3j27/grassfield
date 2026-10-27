// Arch's AppStream (ADR-0037 c, ST5, SD4): parsed for display, every text plain; the fetched copy unpacked only after its
// signature passes pacman's rule (verifyPacmanSignature). pacman, gpg and bsdtar are fakes here; nothing reads the
// system's package manager. RealPackage runs the real gpg and bsdtar on a throwaway pacman keyring in the container of
// tests/integration/store_catalog.sh (STORE_TEST_PACMAN_KEYRINGS).
#include "appstream.h"
#include "appstreamsource.h"
#include "storetest.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

const AppStreamComponent *find(const QList<AppStreamComponent> &list, const QString &id)
{
    for (const AppStreamComponent &c : list) {
        if (c.id == id)
            return &c;
    }
    return nullptr;
}

} // namespace

TEST(AppStream, Gunzip)
{
    const QByteArray xml = storetest::readFixture(QStringLiteral("appstream-extra.xml"));
    const QByteArray gz = storetest::gzip(xml);
    EXPECT_EQ(gunzip(gz, 1 << 20), xml);
    EXPECT_TRUE(gunzip(gz, xml.size() - 1).isEmpty()); // over the cap: nothing, not a cut
    EXPECT_TRUE(gunzip(xml, 1 << 20).isEmpty());         // not gzip
    EXPECT_TRUE(gunzip(gz.left(gz.size() / 2), 1 << 20).isEmpty()); // damaged
}

TEST(AppStream, ComponentsAndTheirPlainTexts)
{
    const QList<AppStreamComponent> list = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
    EXPECT_FALSE(find(list, QStringLiteral("org.example.NoPackage"))); // no pkgname: the Store shows packages
    const AppStreamComponent *gimp = find(list, QStringLiteral("org.gimp.GIMP"));
    ASSERT_TRUE(gimp);
    EXPECT_EQ(gimp->pkgname, QStringLiteral("gimp"));
    EXPECT_EQ(gimp->type, QStringLiteral("desktop-application"));
    EXPECT_EQ(gimp->origin, QStringLiteral("archlinux-arch-extra"));
    EXPECT_EQ(gimp->name.en, QStringLiteral("GNU Image Manipulation Program"));
    EXPECT_EQ(gimp->name.fr, QStringLiteral("Programme de manipulation d'images GNU"));
    EXPECT_EQ(gimp->summary.pick(QStringLiteral("fr")), QStringLiteral("Créer des images et retoucher des photos"));
    // Paragraphs and bullets, inner markup as text, the right-to-left override removed, spaces collapsed.
    EXPECT_EQ(gimp->description.en, QStringLiteral("GIMP is an image editor.\n• Layers\n• Masks and filters"));
    EXPECT_EQ(gimp->description.fr, QStringLiteral("GIMP est un éditeur."));
    EXPECT_EQ(gimp->developer.en, QStringLiteral("The GIMP Team"));
    EXPECT_EQ(gimp->license, QStringLiteral("GPL-3.0-or-later"));
    EXPECT_EQ(gimp->categories, (QStringList{QStringLiteral("Graphics"), QStringLiteral("RasterGraphics")}));
    EXPECT_EQ(gimp->keywords, QStringList{QStringLiteral("photo")});
    EXPECT_EQ(gimp->desktopId, QStringLiteral("gimp.desktop"));
    EXPECT_EQ(gimp->cachedIcon, QStringLiteral("128x128/gimp_org.gimp.GIMP.png")); // the largest cached, at most 512
    EXPECT_EQ(gimp->screenshots, (QStringList{QStringLiteral("https://example.com/first.png"), QStringLiteral("https://example.com/second.png")}));
    EXPECT_EQ(gimp->homepage, QStringLiteral("https://www.gimp.org/"));
    const AppStreamComponent *steam = find(list, QStringLiteral("com.valvesoftware.Steam.desktop"));
    ASSERT_TRUE(steam);
    EXPECT_EQ(steam->developer.en, QStringLiteral("Valve Corporation"));
    EXPECT_TRUE(steam->homepage.isEmpty()); // http: not offered
    EXPECT_EQ(find(list, QStringLiteral("org.example.Cli"))->type, QStringLiteral("console-application"));
}

TEST(AppStream, ReadsEveryCatalogOfAFolder)
{
    QTemporaryDir root;
    QDir().mkpath(root.filePath(QStringLiteral("xml")));
    storetest::writeFile(root.filePath(QStringLiteral("xml/extra.xml.gz")), storetest::gzip(storetest::readFixture(QStringLiteral("appstream-extra.xml"))));
    storetest::writeFile(root.filePath(QStringLiteral("xml/broken.xml.gz")), "not gzip");
    const AppStreamData data = readAppStream(root.path(), AppStreamData::Origin::Installed);
    EXPECT_EQ(data.origin, AppStreamData::Origin::Installed);
    EXPECT_EQ(data.components.size(), 6);
    EXPECT_EQ(readAppStream(root.filePath(QStringLiteral("none")), AppStreamData::Origin::Installed).origin, AppStreamData::Origin::None);
}

TEST(AppStream, ThePackageFilePacmanNames)
{
    const PackageFile f = packageFileFromPrint("https://geo.mirror.pkgbuild.com/extra/os/x86_64/archlinux-appstream-data-20260821-1-any.pkg.tar.zst\n");
    EXPECT_EQ(f.version, QStringLiteral("20260821-1"));
    EXPECT_TRUE(f.url.endsWith(QStringLiteral("-any.pkg.tar.zst")));
    EXPECT_TRUE(packageFileFromPrint("https://m/extra/os/x86_64/other-1-1-any.pkg.tar.zst\n").url.isEmpty());
    EXPECT_TRUE(packageFileFromPrint("").url.isEmpty());
    EXPECT_TRUE(packageFileFromPrint("https://m/archlinux-appstream-data-../../x-any.pkg.tar.zst").url.isEmpty());
}

namespace {

const QByteArray kPackager = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

// Fakes: pacman -Sp prints a URL of a given version; gpg answers --verify with a signer pacman trusts fully, or not, and
// --list-keys with that key valid; bsdtar records its arguments and makes the tree.
struct Tools {
    QTemporaryDir dir;
    AppStreamTools tools;
    QStringList downloads;
    Tools(const QByteArray &version, bool trusted)
    {
        tools.pacman = storetest::script(dir.filePath(QStringLiteral("pacman")),
                                         "echo https://mirror.example/extra/os/x86_64/archlinux-appstream-data-" + version + "-any.pkg.tar.zst");
        tools.gpg = storetest::script(dir.filePath(QStringLiteral("gpg")),
                                      "case \" $* \" in\n"
                                      "*' --verify '*) printf '[GNUPG:] NEWSIG\\n[GNUPG:] GOODSIG 1 Packager\\n[GNUPG:] VALIDSIG " + kPackager
                                          + " 2026-10-27 1 0 4 0 22 10 00 " + kPackager + "\\n[GNUPG:] " + (trusted ? "TRUST_FULLY" : "TRUST_UNDEFINED")
                                          + " 0 pgp\\n' ;;\n"
                                      "*' --list-keys '*) printf 'pub:f:255:22:1:1:::-:::scSC::::::23::0:\\nfpr:::::::::" + kPackager + ":\\n' ;;\n"
                                      "esac");
        // A pacman keyring folder: its files are copied, never used in place.
        tools.pacmanGnupg = dir.filePath(QStringLiteral("gnupg"));
        QDir().mkpath(tools.pacmanGnupg);
        storetest::writeFile(tools.pacmanGnupg + QStringLiteral("/pubring.gpg"), "keys");
        storetest::writeFile(tools.pacmanGnupg + QStringLiteral("/trustdb.gpg"), "trust");
        // bsdtar -x -f <pkg> -C <dir> … usr/share/swcatalog
        const QByteArray gz = storetest::gzip(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
        storetest::writeFile(dir.filePath(QStringLiteral("extra.xml.gz")), gz);
        tools.bsdtar = storetest::script(dir.filePath(QStringLiteral("bsdtar")),
                                         "printf '%s\\n' \"$@\" > '" + dir.filePath(QStringLiteral("bsdtar.args")).toUtf8() + "'\n"
                                         "d=$5; mkdir -p \"$d/usr/share/swcatalog/xml\" && cp '" + dir.filePath(QStringLiteral("extra.xml.gz")).toUtf8()
                                             + "' \"$d/usr/share/swcatalog/xml/\"");
        tools.download = [this](const QString &url, const QString &file, qint64, int) {
            downloads.append(url);
            storetest::writeFile(file, "package bytes");
            return true;
        };
    }
};

} // namespace

TEST(AppStream, AFetchedCopyIsUnpackedOnlyAfterItsSignaturePasses)
{
    QTemporaryDir cache;
    QString error;
    Tools bad("20260821-1", false); // a good signature by a key pacman does not trust fully (S19)
    EXPECT_FALSE(refreshFetched(cache.path(), bad.tools, &error));
    EXPECT_TRUE(error.contains(QStringLiteral("pacman trusts fully"))) << error.toStdString();
    EXPECT_EQ(readFetched(cache.path()).origin, AppStreamData::Origin::None);
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());
    EXPECT_FALSE(QFile::exists(bad.dir.filePath(QStringLiteral("bsdtar.args")))); // nothing unpacked

    // What an interrupted refresh left goes at the start of the next one.
    QDir().mkpath(cache.filePath(QStringLiteral("appstream/.work-left/tree")));
    Tools good("20260821-1", true);
    ASSERT_TRUE(refreshFetched(cache.path(), good.tools, &error)) << error.toStdString();
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/.work-left"))).exists());
    // bsdtar's arguments: only the swcatalog tree, no owner, permission, extended attribute or ACL from the archive.
    QFile args(good.dir.filePath(QStringLiteral("bsdtar.args")));
    ASSERT_TRUE(args.open(QIODevice::ReadOnly));
    const QStringList argv = QString::fromUtf8(args.readAll()).split(u'\n', Qt::SkipEmptyParts);
    ASSERT_EQ(argv.size(), 10);
    EXPECT_EQ(argv.mid(0, 2), (QStringList{QStringLiteral("-x"), QStringLiteral("-f")}));
    EXPECT_TRUE(argv.at(2).startsWith(cache.filePath(QStringLiteral("appstream/.work-"))));
    EXPECT_EQ(argv.at(3), QStringLiteral("-C"));
    EXPECT_TRUE(argv.at(4).startsWith(cache.filePath(QStringLiteral("appstream/.work-"))));
    EXPECT_EQ(argv.mid(5), (QStringList{QStringLiteral("--no-same-owner"), QStringLiteral("--no-same-permissions"), QStringLiteral("--no-xattrs"),
                                       QStringLiteral("--no-acls"), QStringLiteral("usr/share/swcatalog")}));
    EXPECT_EQ(good.downloads, (QStringList{QStringLiteral("https://mirror.example/extra/os/x86_64/archlinux-appstream-data-20260821-1-any.pkg.tar.zst"),
                                           QStringLiteral("https://mirror.example/extra/os/x86_64/archlinux-appstream-data-20260821-1-any.pkg.tar.zst.sig")}));
    AppStreamData data = readFetched(cache.path());
    EXPECT_EQ(data.origin, AppStreamData::Origin::Fetched);
    EXPECT_EQ(data.version, QStringLiteral("20260821-1"));
    EXPECT_EQ(data.components.size(), 6);

    // The same version again: nothing downloaded.
    Tools same("20260821-1", true);
    ASSERT_TRUE(refreshFetched(cache.path(), same.tools, &error));
    EXPECT_TRUE(same.downloads.isEmpty());

    // A newer version whose signature fails: the previous copy stays in use.
    Tools newerBad("20261017-1", false);
    EXPECT_FALSE(refreshFetched(cache.path(), newerBad.tools, &error));
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20260821-1"));

    // A newer good one replaces it, and the old version is removed.
    Tools newer("20261017-1", true);
    ASSERT_TRUE(refreshFetched(cache.path(), newer.tools, &error));
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20261017-1"));
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());
}

// The real gpg and bsdtar (tests/integration/store_catalog.sh): a package made and signed by a throwaway packager key,
// pacman's keyring copied at three moments: the key added but not locally signed, locally signed, then disabled. The
// package also holds members outside usr/share/swcatalog (one named ../escaped): nothing but the tree is unpacked.
TEST(AppStream, RealPackage)
{
    const QString dir = qEnvironmentVariable("STORE_TEST_PACMAN_KEYRINGS");
    if (dir.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    auto refresh = [&](const char *keyring, QTemporaryDir &cache, QString *error) {
        QTemporaryDir bin;
        AppStreamTools tools;
        tools.pacman = storetest::script(bin.filePath(QStringLiteral("pacman")),
                                         "echo https://mirror.example/extra/os/x86_64/archlinux-appstream-data-20261017-1-any.pkg.tar.zst");
        tools.pacmanGnupg = dir + QLatin1Char('/') + QLatin1String(keyring);
        tools.download = [&](const QString &url, const QString &file, qint64, int) {
            return QFile::copy(dir + (url.endsWith(QStringLiteral(".sig")) ? QStringLiteral("/appstream.pkg.tar.zst.sig")
                                                                             : QStringLiteral("/appstream.pkg.tar.zst")),
                               file);
        };
        return refreshFetched(cache.path(), tools, error);
    };
    QString error;
    QTemporaryDir untrusted, disabled, trusted;
    EXPECT_FALSE(refresh("untrusted", untrusted, &error));
    EXPECT_TRUE(error.contains(QStringLiteral("pacman trusts fully"))) << error.toStdString();
    EXPECT_FALSE(refresh("disabled", disabled, &error));
    EXPECT_TRUE(error.contains(QStringLiteral("disabled"))) << error.toStdString();
    ASSERT_TRUE(refresh("trusted", trusted, &error)) << error.toStdString();
    const AppStreamData data = readFetched(trusted.path());
    EXPECT_EQ(data.version, QStringLiteral("20261017-1"));
    EXPECT_EQ(data.components.size(), 6);
    QStringList everything;
    QDirIterator it(trusted.path(), QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (it.hasNext())
        everything.append(it.next().mid(trusted.path().size() + 1));
    everything.sort();
    for (const QString &path : everything)
        EXPECT_TRUE(path == QStringLiteral("appstream") || path == QStringLiteral("appstream/current")
                    || path.startsWith(QStringLiteral("appstream/20261017-1"))) << path.toStdString();
    EXPECT_FALSE(everything.join(u'\n').contains(QStringLiteral("escaped")));
    EXPECT_FALSE(everything.join(u'\n').contains(QStringLiteral(".PKGINFO")));
}
