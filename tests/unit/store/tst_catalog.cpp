// The catalog's rules as the Store applies them (ADR-0037 g; the same rules as grassfield-packages' tools/catalog.py):
// a top-level break refuses the file, an entry's break drops the entry and what only pointed to it.
#include "catalog.h"
#include "storetest.h"

#include <QJsonArray>

#include <gtest/gtest.h>

using namespace grassfield::store;
using storetest::changedCatalog;

namespace {

QJsonArray arr(const QJsonObject &o, const char *key)
{
    return o.value(QLatin1String(key)).toArray();
}

const CatalogApp *app(const Catalog &c, const QString &id)
{
    for (const CatalogApp &a : c.apps) {
        if (a.id == id)
            return &a;
    }
    return nullptr;
}

} // namespace

TEST(Catalog, TheFixtureParsesWhole)
{
    const CatalogParse p = parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog) << p.refusal.toStdString();
    EXPECT_TRUE(p.dropped.isEmpty()) << p.dropped.join(u'\n').toStdString();
    const Catalog &c = *p.catalog;
    EXPECT_EQ(c.serial, 1793095200);
    EXPECT_EQ(c.sections.size(), 2);
    EXPECT_EQ(c.sections.at(0).id, QStringLiteral("discover"));
    EXPECT_EQ(c.sections.at(0).blocks.size(), 3);
    EXPECT_EQ(c.sections.at(0).blocks.at(0).kind, CatalogBlock::Kind::Hero);
    EXPECT_EQ(c.sections.at(0).blocks.at(0).items.at(0).text.en, QStringLiteral("Layers, masks and filters.\nFree."));
    EXPECT_EQ(c.sections.at(0).title.pick(QStringLiteral("fr_FR")), QStringLiteral("Découvrir"));
    EXPECT_EQ(c.categories.at(1).title.pick(QStringLiteral("de")), QStringLiteral("Games"));
    EXPECT_EQ(c.apps.size(), 6);
    const CatalogApp *steam = app(c, QStringLiteral("com.valvesoftware.Steam.desktop"));
    ASSERT_TRUE(steam);
    EXPECT_EQ(steam->source.kind, CatalogSource::Kind::OmarchySetup);
    EXPECT_EQ(steam->source.install, QStringLiteral("omarchy-install-gaming-steam"));
    EXPECT_EQ(steam->source.packages, QStringList{QStringLiteral("steam")});
    EXPECT_EQ(steam->source.removes.en, QStringLiteral("Your Steam folders."));
    const CatalogApp *spotify = app(c, QStringLiteral("com.spotify.Client"));
    ASSERT_TRUE(spotify && spotify->icon);
    EXPECT_EQ(spotify->icon->bytes, 120);
    EXPECT_EQ(spotify->desktopId, QStringLiteral("spotify.desktop"));
}

TEST(Catalog, TopLevelBreaksRefuseTheFile)
{
    struct Case {
        const char *name;
        std::function<void(QJsonObject &)> change;
    };
    const QList<Case> cases = {
        {"version 2", [](QJsonObject &o) { o[QStringLiteral("version")] = 2; }},
        {"version as text", [](QJsonObject &o) { o[QStringLiteral("version")] = QStringLiteral("1"); }},
        {"unknown channel", [](QJsonObject &o) { o[QStringLiteral("channel")] = QStringLiteral("nightly"); }},
        {"serial 0", [](QJsonObject &o) { o[QStringLiteral("serial")] = 0; }},
        {"serial fraction", [](QJsonObject &o) { o[QStringLiteral("serial")] = 1.5; }},
        {"serial as text", [](QJsonObject &o) { o[QStringLiteral("serial")] = QStringLiteral("1"); }},
        {"generated", [](QJsonObject &o) { o[QStringLiteral("generated")] = QStringLiteral("yesterday"); }},
        {"no sections", [](QJsonObject &o) { o[QStringLiteral("sections")] = QJsonArray(); }},
        {"first section is not discover", [](QJsonObject &o) {
             QJsonArray s = arr(o, "sections");
             s.removeFirst();
             o[QStringLiteral("sections")] = s;
         }},
        {"nine sections", [](QJsonObject &o) {
             QJsonArray s;
             for (int i = 0; i < 9; ++i)
                 s.append(arr(o, "sections").at(0));
             o[QStringLiteral("sections")] = s;
         }},
        {"33 categories", [](QJsonObject &o) {
             QJsonArray c;
             for (int i = 0; i < 33; ++i)
                 c.append(arr(o, "categories").at(0));
             o[QStringLiteral("categories")] = c;
         }},
        {"apps not a list", [](QJsonObject &o) { o[QStringLiteral("apps")] = QJsonObject(); }},
    };
    for (const Case &k : cases) {
        const CatalogParse p = parseCatalog(changedCatalog(k.change), QStringLiteral("stable"));
        EXPECT_FALSE(p.catalog) << k.name;
        EXPECT_FALSE(p.refusal.isEmpty()) << k.name;
    }
    EXPECT_FALSE(parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("beta")).catalog);
    EXPECT_FALSE(parseCatalog(QByteArray("[1, 2]"), QStringLiteral("stable")).catalog);
    EXPECT_FALSE(parseCatalog(QByteArray(kCatalogMaxBytes + 1, ' '), QStringLiteral("stable")).catalog);
}

TEST(Catalog, ABrokenEntryIsDroppedAndTheRestKept)
{
    // The web app without its icon is dropped; the row keeps its two other apps.
    CatalogParse p = parseCatalog(changedCatalog([](QJsonObject &o) {
                                      QJsonArray apps = arr(o, "apps");
                                      QJsonObject mail = apps.at(3).toObject();
                                      mail.remove(QStringLiteral("icon"));
                                      apps[3] = mail;
                                      o[QStringLiteral("apps")] = apps;
                                  }),
                                  QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog);
    EXPECT_FALSE(app(*p.catalog, QStringLiteral("org.example.Mail")));
    EXPECT_EQ(p.catalog->sections.at(0).blocks.at(2).apps,
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Flat")}));
    EXPECT_TRUE(p.dropped.join(u'\n').contains(QStringLiteral("app org.example.Mail: a web app without an icon")));

    // Steam's setup names an install recipe of the remove kind (e.5): Steam goes, so does the play section's emptied row
    // only if nothing is left in it (aur-game stays), and the cards block keeps Spotify.
    p = parseCatalog(changedCatalog([](QJsonObject &o) {
                         QJsonArray apps = arr(o, "apps");
                         QJsonObject steam = apps.at(1).toObject();
                         QJsonObject source = steam.value(QStringLiteral("source")).toObject();
                         source[QStringLiteral("install")] = QStringLiteral("omarchy-remove-gaming-steam");
                         steam[QStringLiteral("source")] = source;
                         apps[1] = steam;
                         o[QStringLiteral("apps")] = apps;
                     }),
                     QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog);
    EXPECT_FALSE(app(*p.catalog, QStringLiteral("com.valvesoftware.Steam.desktop")));
    EXPECT_EQ(p.catalog->sections.at(0).blocks.at(1).items.size(), 1);
    EXPECT_EQ(p.catalog->sections.at(1).blocks.at(0).apps, QStringList{QStringLiteral("aur-game")});

    // Both apps of the play section's row gone: the row, then the section, go.
    p = parseCatalog(changedCatalog([](QJsonObject &o) {
                         QJsonArray apps = arr(o, "apps");
                         apps.removeAt(5); // aur-game
                         apps.removeAt(1); // Steam
                         o[QStringLiteral("apps")] = apps;
                     }),
                     QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog);
    EXPECT_EQ(p.catalog->sections.size(), 1);
    EXPECT_TRUE(p.dropped.join(u'\n').contains(QStringLiteral("section play: no block is left")));

    // A duplicated id: which copy CI meant is unknown, both go.
    p = parseCatalog(changedCatalog([](QJsonObject &o) {
                         QJsonArray apps = arr(o, "apps");
                         apps.append(apps.at(0));
                         o[QStringLiteral("apps")] = apps;
                     }),
                     QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog);
    EXPECT_FALSE(app(*p.catalog, QStringLiteral("org.gimp.GIMP")));

    // A category that breaks a rule goes, and so does the app that names it.
    p = parseCatalog(changedCatalog([](QJsonObject &o) {
                         QJsonArray cats = arr(o, "categories");
                         QJsonObject g = cats.at(0).toObject();
                         g[QStringLiteral("symbol")] = QStringLiteral("Not A Symbol");
                         cats[0] = g;
                         o[QStringLiteral("categories")] = cats;
                     }),
                     QStringLiteral("stable"));
    ASSERT_TRUE(p.catalog);
    EXPECT_EQ(p.catalog->categories.size(), 2);
    EXPECT_FALSE(app(*p.catalog, QStringLiteral("org.gimp.GIMP")));
}

TEST(Catalog, EntryRules)
{
    auto appChange = [](int index, const char *key, const QJsonValue &value) {
        return changedCatalog([=](QJsonObject &o) {
            QJsonArray apps = arr(o, "apps");
            QJsonObject a = apps.at(index).toObject();
            a[QLatin1String(key)] = value;
            apps[index] = a;
            o[QStringLiteral("apps")] = apps;
        });
    };
    const QList<QPair<const char *, QByteArray>> cases = {
        {"http homepage", appChange(2, "homepage", QStringLiteral("http://www.spotify.com/"))},
        {"desktop id without .desktop", appChange(2, "desktopId", QStringLiteral("spotify"))},
        {"licence with a space", appChange(2, "license", QStringLiteral("GPL 3"))},
        {"name with a line feed", appChange(2, "name", QJsonObject{{QStringLiteral("en"), QStringLiteral("Spo\ntify")}})},
        {"name without English", appChange(2, "name", QJsonObject{{QStringLiteral("fr"), QStringLiteral("Spotify")}})},
        {"summary with a bidirectional override", appChange(2, "summary", QJsonObject{{QStringLiteral("en"), QStringLiteral("evil") + QChar(0x202E) + QStringLiteral("txt")}})},
        {"a name over 80 characters", appChange(2, "name", QJsonObject{{QStringLiteral("en"), QString(81, u'x')}})},
        {"five categories", appChange(0, "categories", QJsonArray{QStringLiteral("graphics"), QStringLiteral("games"), QStringLiteral("graphics"), QStringLiteral("games"), QStringLiteral("graphics")})},
        {"a source of an unknown kind", appChange(0, "source", QJsonObject{{QStringLiteral("kind"), QStringLiteral("snap")}})},
        {"a repository the Store does not offer", appChange(0, "source", QJsonObject{{QStringLiteral("kind"), QStringLiteral("repo")}, {QStringLiteral("repo"), QStringLiteral("testing")}, {QStringLiteral("package"), QStringLiteral("gimp")}})},
        {"a package name starting with -", appChange(5, "source", QJsonObject{{QStringLiteral("kind"), QStringLiteral("aur")}, {QStringLiteral("package"), QStringLiteral("-rf")}})},
        {"a Flatpak of another remote", appChange(4, "source", QJsonObject{{QStringLiteral("kind"), QStringLiteral("flatpak")}, {QStringLiteral("remote"), QStringLiteral("other")}, {QStringLiteral("app"), QStringLiteral("org.example.Flat")}})},
        {"an icon of 300 KiB", appChange(2, "icon", QJsonObject{{QStringLiteral("sha256"), QString(64, u'a')}, {QStringLiteral("bytes"), 300 * 1024}, {QStringLiteral("license"), QStringLiteral("MIT")}, {QStringLiteral("origin"), QStringLiteral("https://e.com/i.png")}})},
    };
    for (const auto &k : cases) {
        const CatalogParse p = parseCatalog(k.second, QStringLiteral("stable"));
        ASSERT_TRUE(p.catalog) << k.first;
        EXPECT_EQ(p.catalog->apps.size(), 5) << k.first;
        EXPECT_EQ(p.dropped.size() >= 1, true) << k.first;
    }
}

TEST(Catalog, TextRule)
{
    EXPECT_TRUE(plainTextProblem(QStringLiteral("Retouche d'images"), 40, false).isEmpty());
    EXPECT_TRUE(plainTextProblem(QStringLiteral("Line one.\nLine two."), 200, true).isEmpty());
    EXPECT_FALSE(plainTextProblem(QStringLiteral("Line one.\nLine two."), 200, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QString(), 40, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QStringLiteral(" padded"), 40, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QStringLiteral("tab\there"), 40, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QStringLiteral("rtl") + QChar(0x2067) + QStringLiteral("here"), 40, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QStringLiteral("é"), 40, false).isEmpty()); // not NFC
    // Lengths count code points, not UTF-16 units: forty emoji fit a 40 limit.
    EXPECT_TRUE(plainTextProblem(QString::fromUtf8(QByteArray("\xF0\x9F\x8E\xA8").repeated(40)), 40, false).isEmpty());
    EXPECT_FALSE(plainTextProblem(QString::fromUtf8(QByteArray("\xF0\x9F\x8E\xA8").repeated(41)), 40, false).isEmpty());
}

TEST(Catalog, CleanPlainText)
{
    EXPECT_EQ(cleanPlainText(QStringLiteral("  Masks   and\n filters") + QChar(0x202E) + QStringLiteral(" "), 200, false), QStringLiteral("Masks and filters"));
    EXPECT_EQ(cleanPlainText(QStringLiteral("one \n two"), 200, true), QStringLiteral("one\ntwo"));
    EXPECT_EQ(cleanPlainText(QStringLiteral("abcdef"), 4, false), QStringLiteral("abc…"));
}

TEST(Catalog, Patterns)
{
    EXPECT_TRUE(isPackageName(QStringLiteral("lib32-vulkan-radeon")));
    EXPECT_TRUE(isPackageName(QStringLiteral("gtk2+extra@1")));
    EXPECT_FALSE(isPackageName(QStringLiteral("-rf")));
    EXPECT_FALSE(isPackageName(QStringLiteral("Upper")));
    EXPECT_FALSE(isPackageName(QStringLiteral("a b")));
    EXPECT_TRUE(isDesktopId(QStringLiteral("org.gimp.GIMP.desktop")));
    EXPECT_FALSE(isDesktopId(QStringLiteral("Example Mail.desktop"))); // uwsm refuses it too (S14)
    EXPECT_TRUE(isFlatpakId(QStringLiteral("org.inkscape.Inkscape")));
    EXPECT_FALSE(isFlatpakId(QStringLiteral("inkscape")));
    EXPECT_FALSE(isFlatpakId(QStringLiteral("-org.x.y")));
    EXPECT_TRUE(isHttpsUrl(QStringLiteral("https://www.gimp.org/")));
    EXPECT_FALSE(isHttpsUrl(QStringLiteral("http://www.gimp.org/")));
    EXPECT_FALSE(isHttpsUrl(QStringLiteral("https://a b/")));
    EXPECT_FALSE(isHttpsUrl(QStringLiteral("https://")));
}
