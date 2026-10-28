// What the Store's QML shows (spec SR1-SR12, SR23, SR24): the merged model made into plain values, the catalog's sections
// with what the model does not offer left out, the built-in Discover and categories, the hero tint (A2), Omarchy's web app
// launchers, the account's initials and software-update.json read for the Updates list. Pure: fixtures in, maps out.
#include "storemodel.h"
#include "storetest.h"
#include "storeview.h"

#include <QImage>
#include <QPainter>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

// The fixture catalog (or, without it, a catalog of the built-in categories only) over both AppStream fixtures.
struct Fixture {
    Catalog catalog;
    Catalog fallback;
    QList<AppStreamComponent> appstream;
    QList<StoreApp> apps;
    QHash<QString, int> index;
    explicit Fixture(bool withCatalog)
    {
        catalog = *parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("stable")).catalog;
        fallback.categories = view::builtInCategories();
        appstream = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")))
                  + parseAppStream(storetest::readFixture(QStringLiteral("appstream-product.xml")));
        ModelInputs in;
        in.catalog = withCatalog ? &catalog : &fallback;
        in.appstream = appstream;
        in.sync = {{QStringLiteral("extra"), QStringLiteral("gimp"), QStringLiteral("3.0.4-1"), true},
                   {QStringLiteral("multilib"), QStringLiteral("steam"), QStringLiteral("1.0-1"), false},
                   {QStringLiteral("extra"), QStringLiteral("paint"), QStringLiteral("1-1"), false},
                   {QStringLiteral("extra"), QStringLiteral("sketch"), QStringLiteral("2.1-1"), true},
                   {QStringLiteral("extra"), QStringLiteral("cafe"), QStringLiteral("1-1"), false}};
        in.catalogIcon = [](const CatalogIcon &) { return QString(); };
        apps = buildModel(in);
        for (int i = 0; i < apps.size(); ++i)
            index.insert(apps.at(i).id, i);
    }
    Fixture(const Fixture &) = delete; // StoreApp::entry points into `catalog`
    const StoreApp &app(const QString &id) const { return apps.at(index.value(id)); }
};

QStringList ids(const QVariantList &list, const char *key = "id")
{
    QStringList out;
    for (const QVariant &v : list)
        out.append(v.toMap().value(QLatin1String(key)).toString());
    return out;
}

} // namespace

TEST(StoreView, Summary)
{
    const Fixture f(true);
    const QVariantMap gimp = view::summary(f.app(QStringLiteral("org.gimp.GIMP")), QStringLiteral("fr"));
    EXPECT_EQ(gimp.value(QStringLiteral("kind")), QStringLiteral("repo"));
    EXPECT_EQ(gimp.value(QStringLiteral("repo")), QStringLiteral("extra"));
    EXPECT_TRUE(gimp.value(QStringLiteral("installed")).toBool());
    EXPECT_TRUE(gimp.value(QStringLiteral("launcher")).toBool()); // gimp.desktop
    EXPECT_EQ(gimp.value(QStringLiteral("icon")), QString());   // no cached icon in this fixture
    const QVariantMap steam = view::summary(f.app(QStringLiteral("com.valvesoftware.Steam.desktop")), QStringLiteral("en"));
    EXPECT_EQ(steam.value(QStringLiteral("kind")), QStringLiteral("setup"));
    EXPECT_FALSE(steam.value(QStringLiteral("installed")).toBool());
    for (const auto &[kind, name] : {std::pair{CatalogSource::Kind::Aur, "aur"}, std::pair{CatalogSource::Kind::WebApp, "webapp"},
                                     std::pair{CatalogSource::Kind::Flatpak, "flatpak"}})
        EXPECT_EQ(view::sourceKind(kind), QLatin1String(name));
}

TEST(StoreView, ProductPage)
{
    const Fixture f(false);
    const StoreApp &sketch = f.app(QStringLiteral("org.example.Sketch"));
    ASSERT_GE(sketch.component, 0);
    const QLocale en(QStringLiteral("en_US")), fr(QStringLiteral("fr_FR"));
    const QVariantMap d = view::detail(sketch, &f.appstream.at(sketch.component), view::builtInCategories(), QStringLiteral("en"), en);
    EXPECT_EQ(d.value(QStringLiteral("description")), QStringLiteral("The app's own text."));
    EXPECT_EQ(d.value(QStringLiteral("bugtracker")), QStringLiteral("https://sketch.example.org/issues"));
    EXPECT_EQ(d.value(QStringLiteral("captions")).toStringList().size(), 3);
    const QVariantList releases = d.value(QStringLiteral("releases")).toList();
    ASSERT_EQ(releases.size(), 3);
    EXPECT_EQ(releases.at(0).toMap().value(QStringLiteral("date")), QStringLiteral("September 30, 2026"));
    EXPECT_EQ(releases.at(0).toMap().value(QStringLiteral("notes")), QStringLiteral("Faster brushes.\n• New eraser"));
    // Languages by their own names, sorted; the rating's groups and levels for the QML's words.
    EXPECT_EQ(d.value(QStringLiteral("languages")).toStringList(),
              (QStringList{QStringLiteral("Deutsch"), QStringLiteral("français"), QStringLiteral("português")}));
    EXPECT_TRUE(d.value(QStringLiteral("rated")).toBool());
    EXPECT_EQ(d.value(QStringLiteral("rating")).toMap().value(QStringLiteral("social")).toInt(), 3);
    const QVariantMap dfr = view::detail(sketch, &f.appstream.at(sketch.component), view::builtInCategories(), QStringLiteral("fr"), fr);
    EXPECT_EQ(dfr.value(QStringLiteral("releases")).toList().at(0).toMap().value(QStringLiteral("date")), QStringLiteral("30 septembre 2026"));
    EXPECT_EQ(dfr.value(QStringLiteral("releases")).toList().at(0).toMap().value(QStringLiteral("notes")), QStringLiteral("Pinceaux plus rapides."));
    // No AppStream data: no releases, no rating, captions as many as screenshots.
    const QVariantMap bare = view::detail(sketch, nullptr, {}, QStringLiteral("en"), en);
    EXPECT_TRUE(bare.value(QStringLiteral("releases")).toList().isEmpty());
    EXPECT_FALSE(bare.value(QStringLiteral("rated")).toBool());
    EXPECT_EQ(bare.value(QStringLiteral("captions")).toStringList(), QStringList(3, QString()));
}

TEST(StoreView, SetupWebAppAndCategories)
{
    const Fixture f(true);
    const QLocale en(QStringLiteral("en_US"));
    const QVariantMap steam = view::detail(f.app(QStringLiteral("com.valvesoftware.Steam.desktop")), nullptr, f.catalog.categories,
                                           QStringLiteral("fr"), en);
    const QVariantMap setup = steam.value(QStringLiteral("setup")).toMap();
    EXPECT_EQ(setup.value(QStringLiteral("install")), QStringLiteral("omarchy-install-gaming-steam"));
    EXPECT_EQ(setup.value(QStringLiteral("changes")), QStringLiteral("Installe Steam et ses pilotes."));
    EXPECT_EQ(setup.value(QStringLiteral("removes")), QStringLiteral("Your Steam folders.")); // no French: the English
    EXPECT_EQ(steam.value(QStringLiteral("categories")).toStringList().size(), 1);
    const QVariantMap mail = view::detail(f.app(QStringLiteral("org.example.Mail")), nullptr, f.catalog.categories, QStringLiteral("en"), en);
    EXPECT_EQ(mail.value(QStringLiteral("webUrl")), QStringLiteral("https://mail.example.com/"));
}

TEST(StoreView, PackageFacts)
{
    PackageInfo info;
    info.name = QStringLiteral("gimp");
    info.version = QStringLiteral("3.0.4-1");
    info.downloadSize = 21560000;
    info.installedSize = -1;
    info.buildDate = QDate(2026, 10, 15);
    info.licenses = {QStringLiteral("GPL-3.0-or-later"), QStringLiteral("LGPL-3.0-or-later")};
    const QVariantMap en = view::packageFacts(info, QLocale(QStringLiteral("en_US")));
    EXPECT_EQ(en.value(QStringLiteral("downloadSize")), QStringLiteral("21.6 MB"));
    EXPECT_EQ(en.value(QStringLiteral("installedSize")), QString());
    EXPECT_EQ(en.value(QStringLiteral("buildDate")), QStringLiteral("October 15, 2026"));
    EXPECT_EQ(en.value(QStringLiteral("licenses")), QStringLiteral("GPL-3.0-or-later, LGPL-3.0-or-later"));
    const QVariantMap fr = view::packageFacts(info, QLocale(QStringLiteral("fr_FR")));
    EXPECT_EQ(fr.value(QStringLiteral("buildDate")), QStringLiteral("15 octobre 2026"));
    EXPECT_TRUE(fr.value(QStringLiteral("downloadSize")).toString().startsWith(QStringLiteral("21,6")));
}

TEST(StoreView, DayText)
{
    const QDate d(2026, 10, 27);
    EXPECT_EQ(view::dayText(d, QLocale(QStringLiteral("en_US")), false), QStringLiteral("October 27"));
    EXPECT_EQ(view::dayText(d, QLocale(QStringLiteral("en_GB")), false), QStringLiteral("27 October"));
    EXPECT_EQ(view::dayText(d, QLocale(QStringLiteral("fr_FR")), false), QStringLiteral("27 octobre"));
    EXPECT_EQ(view::dayText(d, QLocale(QStringLiteral("en_GB"))), QStringLiteral("27 October 2026"));
    EXPECT_EQ(view::dayText(QDate(), QLocale(QStringLiteral("en_US"))), QString());
}

// The catalog's sections in order; what the model does not offer (Flathub and the AUR off, a package pacman's database
// lacks) is left out, and a block or section left empty goes with it.
TEST(StoreView, SectionsLeaveOutWhatIsNotOffered)
{
    const Fixture f(true);
    const QVariantList out = view::sections(f.catalog, f.apps, f.index, {{QStringLiteral("org.gimp.GIMP"), QStringLiteral("#123456")}},
                                            QStringLiteral("en"));
    ASSERT_EQ(ids(out), (QStringList{QStringLiteral("discover"), QStringLiteral("play")}));
    const QVariantList blocks = out.at(0).toMap().value(QStringLiteral("blocks")).toList();
    ASSERT_EQ(ids(blocks, "kind"), (QStringList{QStringLiteral("hero"), QStringLiteral("cards"), QStringLiteral("row")}));
    const QVariantMap hero = blocks.at(0).toMap().value(QStringLiteral("items")).toList().at(0).toMap();
    EXPECT_EQ(hero.value(QStringLiteral("tint")), QStringLiteral("#123456"));
    EXPECT_EQ(hero.value(QStringLiteral("app")).toMap().value(QStringLiteral("id")), QStringLiteral("org.gimp.GIMP"));
    // Spotify's [omarchy] package is not in this fixture's sync list: only Steam stays in the cards.
    EXPECT_EQ(blocks.at(1).toMap().value(QStringLiteral("items")).toList().size(), 1);
    // The row keeps GIMP and the web app; the Flatpak's source is off.
    EXPECT_EQ(ids(blocks.at(2).toMap().value(QStringLiteral("apps")).toList()),
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Mail")}));
    // Play keeps Steam (its multilib package is there); the AUR game's source is off.
    const QVariantList play = out.at(1).toMap().value(QStringLiteral("blocks")).toList();
    ASSERT_EQ(play.size(), 1);
    EXPECT_EQ(ids(play.at(0).toMap().value(QStringLiteral("apps")).toList()), QStringList{QStringLiteral("com.valvesoftware.Steam.desktop")});
    // Without Steam's package the whole section goes.
    Fixture without(true);
    without.apps.removeAt(without.index.value(QStringLiteral("com.valvesoftware.Steam.desktop")));
    without.index.clear();
    for (int i = 0; i < without.apps.size(); ++i)
        without.index.insert(without.apps.at(i).id, i);
    EXPECT_EQ(ids(view::sections(without.catalog, without.apps, without.index, {}, QStringLiteral("en"))), QStringList{QStringLiteral("discover")});
}

TEST(StoreView, BuiltInDiscoverAndCategories)
{
    const QList<CatalogCategory> categories = view::builtInCategories();
    EXPECT_EQ(categories.size(), 9);
    EXPECT_EQ(categories.at(0).id, QStringLiteral("productivity"));
    EXPECT_EQ(categories.at(1).title.fr, QStringLiteral("Graphisme"));
    const Fixture f(false);
    const QVariantMap discover = view::builtInDiscover(f.apps, categories, QStringLiteral("en"), 1);
    EXPECT_EQ(discover.value(QStringLiteral("id")), QStringLiteral("discover"));
    EXPECT_TRUE(discover.value(QStringLiteral("builtIn")).toBool());
    const QVariantList rows = discover.value(QStringLiteral("blocks")).toList();
    ASSERT_FALSE(rows.isEmpty());
    for (const QVariant &r : rows) {
        EXPECT_EQ(r.toMap().value(QStringLiteral("kind")), QStringLiteral("row"));
        EXPECT_EQ(r.toMap().value(QStringLiteral("apps")).toList().size(), 1); // perRow
    }
    EXPECT_EQ(rows.at(0).toMap().value(QStringLiteral("category")), QStringLiteral("graphics")); // productivity has no app here
}

// A2: white text on the tint holds 4.5:1; a grey icon gives no tint.
TEST(StoreView, HeroTint)
{
    QImage yellow(32, 32, QImage::Format_ARGB32);
    yellow.fill(QColor(QStringLiteral("#FFD64D")));
    const QColor tint = view::heroTint(yellow);
    ASSERT_TRUE(tint.isValid());
    EXPECT_GE(view::contrast(tint, Qt::white), 4.5);
    EXPECT_GT(tint.redF(), tint.blueF()); // still a yellow, darkened
    QImage grey(32, 32, QImage::Format_ARGB32);
    grey.fill(QColor(128, 128, 128));
    EXPECT_FALSE(view::heroTint(grey).isValid());
    QImage clear(32, 32, QImage::Format_ARGB32);
    clear.fill(Qt::transparent);
    EXPECT_FALSE(view::heroTint(clear).isValid());
    EXPECT_FALSE(view::heroTint(QImage()).isValid());
    EXPECT_NEAR(view::contrast(Qt::black, Qt::white), 21.0, 0.01);
}

// omarchy-webapp-install's launcher: Exec quoted per the Exec spec inside a Desktop Entry string (Omarchy 4.0.4).
TEST(StoreView, WebAppLaunchers)
{
    const auto entry = view::parseWebAppEntry(
        "[Desktop Entry]\nVersion=1.0\nName=Mail\\sBox\nComment=Mail\nExec=omarchy-launch-webapp \"https://mail.example.com/?q=100%%25\"\n"
        "Terminal=false\nType=Application\nIcon=mail-box\n");
    ASSERT_TRUE(entry);
    EXPECT_EQ(entry->name, QStringLiteral("Mail Box"));
    EXPECT_EQ(entry->url, QStringLiteral("https://mail.example.com/?q=100%25"));
    EXPECT_EQ(entry->icon, QStringLiteral("mail-box"));
    // Older launchers: the URL bare.
    EXPECT_TRUE(view::parseWebAppEntry("[Desktop Entry]\nName=HEY\nExec=omarchy-launch-webapp https://app.hey.com\n"));
    // Not a plain web app: another command, a custom command line, no host, a scheme Chromium would run, no name.
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=firefox https://x.example\n"));
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=omarchy-launch-webapp \"https://x.example\" --flag\n"));
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=omarchy-launch-webapp \"javascript:alert(1)\"\n"));
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=omarchy-launch-webapp \"https://\n"));
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=omarchy-launch-webapp \"https://x.example/100%%\"\n")); // a bare %
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nExec=omarchy-launch-webapp https://x.example\n"));
    // Another group's Exec does not count.
    EXPECT_FALSE(view::parseWebAppEntry("[Desktop Entry]\nName=X\nExec=sh\n[Desktop Action a]\nExec=omarchy-launch-webapp https://x.example\n"));
    EXPECT_FALSE(view::parseWebAppEntry(QByteArray(70 * 1024, 'a')));
}

TEST(StoreView, Initials)
{
    EXPECT_EQ(view::initials(QStringLiteral("Ada Lovelace")), QStringLiteral("AL"));
    EXPECT_EQ(view::initials(QStringLiteral("  émile   zola  ")), QStringLiteral("ÉZ"));
    EXPECT_EQ(view::initials(QStringLiteral("Grace Brewster Murray Hopper")), QStringLiteral("GH"));
    EXPECT_EQ(view::initials(QStringLiteral("root")), QStringLiteral("R"));
    EXPECT_EQ(view::initials(QString::fromUtf8("\xF0\x9F\x8C\xB1 Grass")), QString::fromUtf8("\xF0\x9F\x8C\xB1G")); // a whole code point
    EXPECT_EQ(view::initials(QString()), QString());
}

TEST(StoreView, Updates)
{
    const Fixture f(true);
    const QLocale en(QStringLiteral("en_US"));
    const QByteArray json = R"({"version":1,"state":"available","channel":"stable","checkedAt":"2026-10-27T10:00:00Z",
        "lastSuccessAt":"2026-10-27T10:00:00Z","grassfield":{"installed":"1.0.0-1","available":"1.0.1-1"},
        "omarchy":{"installed":"4.0.4-1","available":null},"others":5,
        "otherPackages":[{"name":"gimp","installed":"3.0.4-1","available":"3.0.6-1"},{"name":"glibc","installed":"2.42-1","available":"2.42-2"}]})";
    const QVariantMap u = view::updates(json, f.apps, QStringLiteral("en"), en);
    EXPECT_EQ(u.value(QStringLiteral("state")), QStringLiteral("available"));
    EXPECT_EQ(u.value(QStringLiteral("grassfield")).toMap().value(QStringLiteral("available")), QStringLiteral("1.0.1-1"));
    EXPECT_EQ(u.value(QStringLiteral("omarchy")).toMap().value(QStringLiteral("available")), QString());
    const QVariantList apps = u.value(QStringLiteral("apps")).toList();
    ASSERT_EQ(apps.size(), 1);
    EXPECT_EQ(apps.at(0).toMap().value(QStringLiteral("id")), QStringLiteral("org.gimp.GIMP"));
    EXPECT_EQ(apps.at(0).toMap().value(QStringLiteral("to")), QStringLiteral("3.0.6-1"));
    EXPECT_EQ(u.value(QStringLiteral("otherCount")).toInt(), 4);
    EXPECT_TRUE(u.value(QStringLiteral("listed")).toBool());
    EXPECT_FALSE(u.value(QStringLiteral("checkedAt")).toString().isEmpty());
    // Before Software Update's step 2 the list is not there: only the count.
    const QVariantMap counted = view::updates(R"({"version":1,"state":"up-to-date","others":0})", f.apps, QStringLiteral("en"), en);
    EXPECT_FALSE(counted.value(QStringLiteral("listed")).toBool());
    for (const QByteArray &bad : {QByteArray(), QByteArray("{"), QByteArray(R"({"version":2,"state":"available"})"),
                                  QByteArray(R"({"version":1,"state":"sideways"})"), QByteArray(R"([1])")})
        EXPECT_EQ(view::updates(bad, f.apps, QStringLiteral("en"), en).value(QStringLiteral("state")), QStringLiteral("unknown")) << bad.constData();
}
