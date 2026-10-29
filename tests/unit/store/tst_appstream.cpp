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

// Flathub's AppStream (step 3c): a component needs no pkgname when its bundle is a Flatpak app's; its runtime and the
// verified-developer flag are read, a runtime attribute that is not one is dropped, other bundles are not Flatpaks.
TEST(AppStream, FlathubComponents)
{
    const QList<AppStreamComponent> list = parseAppStream(storetest::readFixture(QStringLiteral("appstream-flathub.xml")));
    const AppStreamComponent *notes = find(list, QStringLiteral("org.example.Notes"));
    ASSERT_TRUE(notes);
    EXPECT_TRUE(notes->pkgname.isEmpty());
    EXPECT_EQ(notes->origin, QStringLiteral("flatpak"));
    EXPECT_EQ(notes->flatpak, QStringLiteral("org.example.Notes"));
    EXPECT_EQ(notes->runtime, QStringLiteral("org.gnome.Platform/x86_64/50"));
    EXPECT_TRUE(notes->verified);
    EXPECT_EQ(notes->name.fr, QStringLiteral("Notes d'exemple"));
    EXPECT_EQ(notes->developer.en, QStringLiteral("Example Developers"));
    EXPECT_EQ(notes->desktopId, QStringLiteral("org.example.Notes.desktop"));
    EXPECT_EQ(notes->cachedIcon, QStringLiteral("128x128/org.example.Notes.png"));
    const AppStreamComponent *paint = find(list, QStringLiteral("org.example.Paint"));
    ASSERT_TRUE(paint);
    EXPECT_EQ(paint->flatpak, QStringLiteral("org.example.Paint"));
    EXPECT_TRUE(paint->runtime.isEmpty()); // "…/25.08;rm" is not a runtime
    EXPECT_FALSE(paint->verified);         // "false", and another key saying "true"
    EXPECT_FALSE(find(list, QStringLiteral("org.example.Platform"))); // a runtime's bundle: no app
    EXPECT_FALSE(find(list, QStringLiteral("notanid")));
    EXPECT_FALSE(find(list, QStringLiteral("org.example.Packaged"))); // not a Flatpak bundle, and no pkgname
    EXPECT_TRUE(isFlatpakRuntime(QStringLiteral("org.freedesktop.Platform/x86_64/25.08")));
    EXPECT_FALSE(isFlatpakRuntime(QStringLiteral("org.freedesktop.Platform/x86_64")));
    EXPECT_FALSE(isFlatpakRuntime(QStringLiteral("../x/x86_64/1")));
    // Arch's components keep their own rule: a pkgname, no Flatpak fields.
    const AppStreamComponent *gimp = find(parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml"))), QStringLiteral("org.gimp.GIMP"));
    ASSERT_TRUE(gimp);
    EXPECT_TRUE(gimp->flatpak.isEmpty());
    EXPECT_FALSE(gimp->verified);
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
    EXPECT_EQ(refreshFetched(cache.path(), bad.tools, &error), RefreshProblem::Unverified);
    EXPECT_TRUE(error.contains(QStringLiteral("pacman trusts fully"))) << error.toStdString();
    EXPECT_EQ(readFetched(cache.path()).origin, AppStreamData::Origin::None);
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());
    EXPECT_FALSE(QFile::exists(bad.dir.filePath(QStringLiteral("bsdtar.args")))); // nothing unpacked

    // What an interrupted refresh left goes at the start of the next one.
    QDir().mkpath(cache.filePath(QStringLiteral("appstream/.work-left/tree")));
    Tools good("20260821-1", true);
    ASSERT_EQ(refreshFetched(cache.path(), good.tools, &error), RefreshProblem::None) << error.toStdString();
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
    ASSERT_EQ(refreshFetched(cache.path(), same.tools, &error), RefreshProblem::None);
    EXPECT_TRUE(same.downloads.isEmpty());

    // A newer version whose signature fails: the previous copy stays in use.
    Tools newerBad("20261017-1", false);
    EXPECT_EQ(refreshFetched(cache.path(), newerBad.tools, &error), RefreshProblem::Unverified);
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20260821-1"));

    // A newer good one replaces it, and the old version is removed.
    Tools newer("20261017-1", true);
    ASSERT_EQ(refreshFetched(cache.path(), newer.tools, &error), RefreshProblem::None);
    EXPECT_EQ(readFetched(cache.path()).version, QStringLiteral("20261017-1"));
    EXPECT_FALSE(QDir(cache.filePath(QStringLiteral("appstream/20260821-1"))).exists());
}

// Each reason of a refresh that fails has its own value (the integrator's note on PR #36: the owner's Store said "could not
// be verified" for a package file its mirror no longer had): the package file the mirror does not serve (404), its .sig
// not served, a signature that fails pacman's rule, no package file named; the previous copy stays in use each time and
// nothing is unpacked.
TEST(AppStream, EachRefreshProblemIsItsOwn)
{
    QTemporaryDir cache;
    QString detail;
    Tools gone("20261017-1", true);
    gone.tools.download = [&gone](const QString &url, const QString &, qint64, int) {
        gone.downloads.append(url);
        return false; // the mirror answers 404: fetch.h gives up
    };
    EXPECT_EQ(refreshFetched(cache.path(), gone.tools, &detail), RefreshProblem::Download);
    EXPECT_TRUE(detail.contains(QStringLiteral("package file could not be downloaded"))) << detail.toStdString();
    EXPECT_EQ(gone.downloads.size(), 1); // the .sig is not asked for then

    Tools noSig("20261017-1", true);
    noSig.tools.download = [&noSig](const QString &url, const QString &file, qint64, int) {
        noSig.downloads.append(url);
        if (url.endsWith(QStringLiteral(".sig")))
            return false;
        storetest::writeFile(file, "package bytes");
        return true;
    };
    EXPECT_EQ(refreshFetched(cache.path(), noSig.tools, &detail), RefreshProblem::SignatureDownload);
    EXPECT_TRUE(detail.endsWith(QStringLiteral(".sig: the signature could not be downloaded"))) << detail.toStdString();

    Tools untrusted("20261017-1", false);
    EXPECT_EQ(refreshFetched(cache.path(), untrusted.tools, &detail), RefreshProblem::Unverified);

    Tools none("20261017-1", true);
    none.tools.pacman = storetest::script(none.dir.filePath(QStringLiteral("pacman")), "echo 'error: target not found' >&2; exit 1");
    EXPECT_EQ(refreshFetched(cache.path(), none.tools, &detail), RefreshProblem::NoPackageFile);

    for (const Tools *t : {&gone, &noSig, &untrusted, &none})
        EXPECT_FALSE(QFile::exists(t->dir.filePath(QStringLiteral("bsdtar.args")))); // nothing unpacked
    EXPECT_EQ(readFetched(cache.path()).origin, AppStreamData::Origin::None);
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
        return refreshFetched(cache.path(), tools, error) == RefreshProblem::None;
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

// The product page's facts (spec SR10, SR11): only the component's own children count, so an <id> of <provides>,
// <suggests> or <extends>, or the <name> and <description> of an <agreement> or a <release>, never replaces its own.
TEST(AppStream, ProductPageFacts)
{
    const QList<AppStreamComponent> list = parseAppStream(storetest::readFixture(QStringLiteral("appstream-product.xml")));
    ASSERT_EQ(list.size(), 2);
    const AppStreamComponent &c = list.at(0);
    EXPECT_EQ(c.id, QStringLiteral("org.example.Sketch"));
    EXPECT_EQ(c.name.en, QStringLiteral("Sketch Pad"));
    EXPECT_EQ(c.description.en, QStringLiteral("The app's own text."));
    EXPECT_EQ(c.homepage, QStringLiteral("https://sketch.example.org/"));
    EXPECT_EQ(c.bugtracker, QStringLiteral("https://sketch.example.org/issues"));
    // The default screenshot first, each with its English caption ("" for none).
    EXPECT_EQ(c.screenshots, (QStringList{QStringLiteral("https://sketch.example.org/1.png"), QStringLiteral("https://sketch.example.org/2.png"),
                                          QStringLiteral("https://sketch.example.org/3.png")}));
    EXPECT_EQ(c.screenshotCaptions, (QStringList{QStringLiteral("The first one"), QStringLiteral("The second one"), QString()}));
    // Three releases at most, newest first as listed; the day from `date`, else `timestamp`, else none.
    ASSERT_EQ(c.releases.size(), 3);
    EXPECT_EQ(c.releases.at(0).version, QStringLiteral("2.1"));
    EXPECT_EQ(c.releases.at(0).date, QStringLiteral("2026-09-30"));
    EXPECT_EQ(c.releases.at(0).description.en, QStringLiteral("Faster brushes.\n• New eraser"));
    EXPECT_EQ(c.releases.at(0).description.fr, QStringLiteral("Pinceaux plus rapides."));
    EXPECT_EQ(c.releases.at(1).date, QStringLiteral("2026-01-01"));
    EXPECT_EQ(c.releases.at(2).version, QStringLiteral("1.9"));
    EXPECT_TRUE(c.releases.at(2).date.isEmpty());
    // OARS: the strongest level of each group; none and unknown groups are left out.
    EXPECT_TRUE(c.rated);
    EXPECT_EQ(c.rating, (QMap<QString, int>{{QStringLiteral("violence"), 2}, {QStringLiteral("social"), 3}}));
    // Languages translated at least by half, or without a percentage; a code that is not one is dropped.
    EXPECT_EQ(c.languages, (QStringList{QStringLiteral("fr"), QStringLiteral("de_DE"), QStringLiteral("pt_BR")}));
    // An empty <content_rating> is a rating with nothing in it; no element at all is no rating.
    EXPECT_TRUE(list.at(1).rated);
    EXPECT_TRUE(list.at(1).rating.isEmpty());
    const QList<AppStreamComponent> extra = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
    EXPECT_FALSE(find(extra, QStringLiteral("org.gimp.GIMP"))->rated);
}
