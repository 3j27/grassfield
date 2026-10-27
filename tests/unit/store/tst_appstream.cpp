// Arch's AppStream (ADR-0037 c, ST5, SD4): parsed for display, every text plain; the fetched copy unpacked only after
// pacman-key --verify passes. pacman, pacman-key and bsdtar are fakes here; nothing reads the system's package manager.
#include "appstream.h"
#include "appstreamsource.h"
#include "storetest.h"

#include <QDir>
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

// Fakes: pacman -Sp prints a URL of a given version; pacman-key --verify exits as `verify` says; bsdtar makes the tree.
struct Tools {
    QTemporaryDir dir;
    AppStreamTools tools;
    QStringList downloads;
    Tools(const QByteArray &version, int verifyExit)
    {
        tools.pacman = storetest::script(dir.filePath(QStringLiteral("pacman")),
                                         "echo https://mirror.example/extra/os/x86_64/archlinux-appstream-data-" + version + "-any.pkg.tar.zst");
        tools.pacmanKey = storetest::script(dir.filePath(QStringLiteral("pacman-key")), "exit " + QByteArray::number(verifyExit));
        // bsdtar -x -f <pkg> -C <dir> … usr/share/swcatalog
        const QByteArray gz = storetest::gzip(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
        storetest::writeFile(dir.filePath(QStringLiteral("extra.xml.gz")), gz);
        tools.bsdtar = storetest::script(dir.filePath(QStringLiteral("bsdtar")),
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
    Tools bad("20260821-1", 1);
    EXPECT_FALSE(refreshFetched(cache.path(), bad.tools, &error));
    EXPECT_EQ(readFetched(cache.path()).origin, AppStreamData::Origin::None);
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());

    Tools good("20260821-1", 0);
    ASSERT_TRUE(refreshFetched(cache.path(), good.tools, &error)) << error.toStdString();
    EXPECT_EQ(good.downloads, (QStringList{QStringLiteral("https://mirror.example/extra/os/x86_64/archlinux-appstream-data-20260821-1-any.pkg.tar.zst"),
                                           QStringLiteral("https://mirror.example/extra/os/x86_64/archlinux-appstream-data-20260821-1-any.pkg.tar.zst.sig")}));
    AppStreamData data = readFetched(cache.path());
    EXPECT_EQ(data.origin, AppStreamData::Origin::Fetched);
    EXPECT_EQ(data.version, QStringLiteral("20260821-1"));
    EXPECT_EQ(data.components.size(), 6);

    // The same version again: nothing downloaded.
    Tools same("20260821-1", 0);
    ASSERT_TRUE(refreshFetched(cache.path(), same.tools, &error));
    EXPECT_TRUE(same.downloads.isEmpty());

    // A newer version whose signature fails: the previous copy stays in use.
    Tools newerBad("20261017-1", 1);
    EXPECT_FALSE(refreshFetched(cache.path(), newerBad.tools, &error));
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20260821-1"));

    // A newer good one replaces it, and the old version is removed.
    Tools newer("20261017-1", 0);
    ASSERT_TRUE(refreshFetched(cache.path(), newer.tools, &error));
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20261017-1"));
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());
}
