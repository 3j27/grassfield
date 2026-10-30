// The apps the Store shows (ADR-0037 a, c; spec SR5-SR8): our catalog over AppStream over pacman, and the local search.
#include "catalog.h"
#include "storemodel.h"
#include "storetest.h"

#include <QDir>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

struct Model {
    Catalog catalog;
    QTemporaryDir icons;
    QList<StoreApp> apps;
    explicit Model(bool aur = false, bool flathub = false, QList<SyncPackage> sync = {})
    {
        catalog = *parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("stable")).catalog;
        // Arch ships cached icons as .jxl whatever the XML names.
        QDir().mkpath(icons.filePath(QStringLiteral("icons/archlinux-arch-extra/128x128")));
        storetest::writeFile(icons.filePath(QStringLiteral("icons/archlinux-arch-extra/128x128/gimp_org.gimp.GIMP.jxl")), "jxl");
        if (sync.isEmpty()) {
            sync = {{QStringLiteral("extra"), QStringLiteral("gimp"), QStringLiteral("3.0.4-1"), true},
                    {QStringLiteral("multilib"), QStringLiteral("steam"), QStringLiteral("1.0-1"), false},
                    {QStringLiteral("omarchy"), QStringLiteral("spotify"), QStringLiteral("1.2-1"), false},
                    {QStringLiteral("extra"), QStringLiteral("paint"), QStringLiteral("1-1"), false},
                    {QStringLiteral("extra"), QStringLiteral("cli-tool"), QStringLiteral("1-1"), false},
                    {QStringLiteral("extra"), QStringLiteral("cafe"), QStringLiteral("1-1"), false}};
        }
        ModelInputs in;
        in.catalog = &catalog;
        in.appstream = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
        in.appstreamRoot = icons.path();
        in.sync = sync;
        in.aurOn = aur;
        in.flathubOn = flathub;
        in.catalogIcon = [](const CatalogIcon &i) { return QStringLiteral("/cache/icons/") + i.sha256 + QStringLiteral(".png"); };
        apps = buildModel(in);
    }
    const StoreApp *find(const QString &id) const
    {
        for (const StoreApp &a : apps) {
            if (a.id == id)
                return &a;
        }
        return nullptr;
    }
};

} // namespace

TEST(StoreModel, OurCatalogOverAppStreamOverPacman)
{
    const Model m;
    const StoreApp *gimp = m.find(QStringLiteral("org.gimp.GIMP"));
    ASSERT_TRUE(gimp);
    EXPECT_TRUE(gimp->inCatalog && gimp->hasAppStream && gimp->installed);
    EXPECT_EQ(gimp->repo, QStringLiteral("extra"));
    EXPECT_EQ(gimp->name.en, QStringLiteral("GNU Image Manipulation Program")); // ours has no name: AppStream's
    EXPECT_EQ(gimp->license, QStringLiteral("GPL-3.0-or-later"));
    EXPECT_TRUE(gimp->icon.endsWith(QStringLiteral("128x128/gimp_org.gimp.GIMP.jxl")));
    EXPECT_EQ(gimp->categories, QStringList{QStringLiteral("graphics")});

    // No AppStream: our texts, our icon (ST10), our licence.
    const StoreApp *spotify = m.find(QStringLiteral("com.spotify.Client"));
    ASSERT_TRUE(spotify);
    EXPECT_FALSE(spotify->hasAppStream);
    EXPECT_EQ(spotify->summary.pick(QStringLiteral("fr")), QStringLiteral("Écoutez de la musique."));
    EXPECT_EQ(spotify->icon, QStringLiteral("/cache/icons/6a1f5f1c0c5b7ecfba5b2a56b2ea3cb8a8bf4a1c0d1a9cc2f3f1b0e7d6c5b4a3.png"));
    EXPECT_EQ(spotify->license, QStringLiteral("LicenseRef-proprietary"));

    // A setup: AppStream's metadata under its id, installed only when every package is.
    const StoreApp *steam = m.find(QStringLiteral("com.valvesoftware.Steam.desktop"));
    ASSERT_TRUE(steam);
    EXPECT_EQ(steam->source, CatalogSource::Kind::OmarchySetup);
    EXPECT_EQ(steam->developer.en, QStringLiteral("Valve Corporation"));
    EXPECT_FALSE(steam->installed);

    EXPECT_TRUE(m.find(QStringLiteral("org.example.Mail"))); // a web app needs no package
}

TEST(StoreModel, WhatIsHidden)
{
    const Model m;
    EXPECT_FALSE(m.find(QStringLiteral("aur-game")));          // the AUR is off
    EXPECT_FALSE(m.find(QStringLiteral("org.example.Flat")));  // Flathub is off
    EXPECT_FALSE(m.find(QStringLiteral("org.example.Gone")));  // its package is in no repository
    EXPECT_FALSE(m.find(QStringLiteral("org.example.Cli")));   // not a desktop application (SD1)
    const Model on(true, true);
    EXPECT_TRUE(on.find(QStringLiteral("aur-game")));
    EXPECT_FALSE(on.find(QStringLiteral("org.example.Flat"))) << "Flathub is on but has no such app (StoreModel.Flathub)";

    // pacman's database without gimp in [extra], nor steam: the catalog entries go with them.
    const Model bare(false, false, {{QStringLiteral("testing"), QStringLiteral("gimp"), QStringLiteral("3-1"), false},
                                    {QStringLiteral("omarchy"), QStringLiteral("spotify"), QStringLiteral("1-1"), false}});
    EXPECT_FALSE(bare.find(QStringLiteral("org.gimp.GIMP")));
    EXPECT_FALSE(bare.find(QStringLiteral("com.valvesoftware.Steam.desktop")));
    EXPECT_TRUE(bare.find(QStringLiteral("com.spotify.Client")));
}

TEST(StoreModel, AppStreamAppsOurCatalogDoesNotList)
{
    const Model m;
    const StoreApp *paint = m.find(QStringLiteral("org.example.Paint"));
    ASSERT_TRUE(paint);
    EXPECT_FALSE(paint->inCatalog);
    EXPECT_EQ(paint->repo, QStringLiteral("extra"));
    EXPECT_EQ(paint->categories, QStringList{QStringLiteral("graphics")}); // 2DGraphics, gathered by our graphics category
    // Each app once: gimp is not added a second time by AppStream.
    int gimps = 0;
    for (const StoreApp &a : m.apps)
        gimps += a.packages.contains(QStringLiteral("gimp"));
    EXPECT_EQ(gimps, 1);
    // Sorted by name.
    for (int i = 1; i < m.apps.size(); ++i)
        EXPECT_LE(m.apps.at(i - 1).name.en.toCaseFolded().compare(m.apps.at(i).name.en.toCaseFolded()), 0);
}

TEST(StoreModel, AppStreamOverlaysOnlyTheEntrysOwnPackage)
{
    // A catalog entry with GIMP's AppStream id but another package: it gets none of GIMP's texts, icon or desktop id
    // (step 3 would open the wrong app), and GIMP itself is not offered a second time.
    Catalog catalog = *parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("stable")).catalog;
    for (CatalogApp &e : catalog.apps) {
        if (e.id == QStringLiteral("org.gimp.GIMP"))
            e.source.package = QStringLiteral("paint");
    }
    ModelInputs in;
    in.catalog = &catalog;
    in.appstream = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
    in.sync = {{QStringLiteral("extra"), QStringLiteral("gimp"), QStringLiteral("3-1"), false},
               {QStringLiteral("extra"), QStringLiteral("paint"), QStringLiteral("1-1"), false}};
    const QList<StoreApp> apps = buildModel(in);
    const StoreApp *entry = nullptr;
    for (const StoreApp &a : apps) {
        if (a.id == QStringLiteral("org.gimp.GIMP"))
            entry = &a;
    }
    ASSERT_TRUE(entry);
    EXPECT_EQ(entry->packages, QStringList{QStringLiteral("paint")});
    EXPECT_FALSE(entry->hasAppStream);
    EXPECT_TRUE(entry->desktopId.isEmpty());
    EXPECT_NE(entry->name.en, QStringLiteral("GNU Image Manipulation Program"));
}

TEST(StoreModel, NoCatalogYet)
{
    ModelInputs in;
    in.appstream = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
    in.sync = {{QStringLiteral("extra"), QStringLiteral("gimp"), QStringLiteral("3-1"), false}};
    const QList<StoreApp> apps = buildModel(in);
    ASSERT_EQ(apps.size(), 1);
    EXPECT_EQ(apps.at(0).id, QStringLiteral("org.gimp.GIMP"));
    EXPECT_TRUE(apps.at(0).categories.isEmpty());
}

TEST(StoreModel, Search)
{
    const Model m(true, true);
    auto ids = [&](const QString &q, const QString &lang = QStringLiteral("en")) {
        QStringList out;
        for (int i : searchApps(m.apps, q, lang))
            out.append(m.apps.at(i).id);
        return out;
    };
    EXPECT_TRUE(ids(QString()).isEmpty());
    EXPECT_EQ(ids(QStringLiteral("gnu")).value(0), QStringLiteral("org.gimp.GIMP"));     // name prefix
    EXPECT_EQ(ids(QStringLiteral("manipulation")).value(0), QStringLiteral("org.gimp.GIMP")); // a word of the name
    EXPECT_EQ(ids(QStringLiteral("photo")), QStringList{QStringLiteral("org.gimp.GIMP")});    // keyword
    EXPECT_EQ(ids(QStringLiteral("cafe ecrit")), QStringList{QStringLiteral("org.example.Cafe")}); // accents and case ignored
    EXPECT_EQ(ids(QStringLiteral("COFFEE")), QStringList{QStringLiteral("org.example.Cafe")});     // summary
    EXPECT_EQ(ids(QStringLiteral("musique"), QStringLiteral("fr")), QStringList{QStringLiteral("com.spotify.Client")});
    EXPECT_TRUE(ids(QStringLiteral("musique"), QStringLiteral("en")).isEmpty());
    // Name prefixes before summaries: "steam" names Steam and is in no other name.
    EXPECT_EQ(ids(QStringLiteral("steam")).value(0), QStringLiteral("com.valvesoftware.Steam.desktop"));
    EXPECT_EQ(searchApps(m.apps, QStringLiteral("a"), QStringLiteral("en"), 2).size(), 2);
}

TEST(StoreModel, Categories)
{
    const Model m(true, true);
    QStringList games;
    for (int i : appsInCategory(m.apps, QStringLiteral("games")))
        games.append(m.apps.at(i).id);
    games.sort();
    EXPECT_EQ(games, (QStringList{QStringLiteral("aur-game"), QStringLiteral("com.valvesoftware.Steam.desktop")}));
}

// Flathub (step 3c): its desktop applications while it is on, after the catalog's and Arch's (an app in several sources
// shows the first of setup, repository, Flathub, AUR), with Flathub's ref, runtime, verified flag and icon; the catalog's
// entry of source flatpak takes Flathub's data.
TEST(StoreModel, Flathub)
{
    Catalog catalog = *parseCatalog(storetest::readFixture(QStringLiteral("catalog-good.json")), QStringLiteral("stable")).catalog;
    QTemporaryDir root;
    QDir().mkpath(root.filePath(QStringLiteral("icons/128x128")));
    storetest::writeFile(root.filePath(QStringLiteral("icons/128x128/org.example.Notes.png")), "png");
    QList<AppStreamComponent> flathub = parseAppStream(storetest::readFixture(QStringLiteral("appstream-flathub.xml")));
    const auto add = [&flathub](const char *id) {
        AppStreamComponent c;
        c.id = QLatin1String(id);
        c.type = QStringLiteral("desktop-application");
        c.flatpak = c.id;
        c.flatpakRef = QStringLiteral("app/%1/x86_64/stable").arg(c.id);
        c.name.en = QStringLiteral("Flathub's ") + c.id;
        flathub.append(c);
    };
    add("org.example.Flat");              // the catalog's entry of source flatpak
    add("com.valvesoftware.Steam");       // Arch names it com.valvesoftware.Steam.desktop: the same app
    ModelInputs in;
    in.catalog = &catalog;
    in.appstream = parseAppStream(storetest::readFixture(QStringLiteral("appstream-extra.xml")));
    in.sync = {{QStringLiteral("extra"), QStringLiteral("paint"), QStringLiteral("1-1"), false},
               {QStringLiteral("multilib"), QStringLiteral("steam"), QStringLiteral("1.0-1"), false}};
    in.flathubOn = true;
    in.flathub = flathub;
    in.flathubRoot = root.path();
    in.flatpaks = {QStringLiteral("org.example.Notes")};
    const QList<StoreApp> apps = buildModel(in);
    const auto find = [&apps](const char *id) -> const StoreApp * {
        for (const StoreApp &a : apps) {
            if (a.id == QLatin1String(id))
                return &a;
        }
        return nullptr;
    };

    const StoreApp *notes = find("org.example.Notes");
    ASSERT_TRUE(notes);
    EXPECT_EQ(notes->source, CatalogSource::Kind::Flatpak);
    EXPECT_TRUE(notes->installed) << "flatpak list --user --app has it";
    EXPECT_FALSE(notes->inCatalog);
    EXPECT_EQ(notes->flatpakRef, QStringLiteral("app/org.example.Notes/x86_64/stable"));
    EXPECT_EQ(notes->runtime, QStringLiteral("org.gnome.Platform/x86_64/50"));
    EXPECT_TRUE(notes->verified);
    EXPECT_EQ(notes->desktopId, QStringLiteral("org.example.Notes.desktop"));
    EXPECT_EQ(notes->icon, root.filePath(QStringLiteral("icons/128x128/org.example.Notes.png")));
    EXPECT_EQ(notes->name.pick(QStringLiteral("fr")), QStringLiteral("Notes d'exemple"));
    EXPECT_EQ(notes->license, QStringLiteral("GPL-3.0-or-later"));
    ASSERT_GE(notes->component, 0);
    EXPECT_EQ(in.flathub.at(notes->component).id, QStringLiteral("org.example.Notes"));

    // Arch's package first: the same id, and Arch's ".desktop" spelling of it.
    const StoreApp *paint = find("org.example.Paint");
    ASSERT_TRUE(paint);
    EXPECT_EQ(paint->source, CatalogSource::Kind::Repo);
    EXPECT_FALSE(find("com.valvesoftware.Steam"));
    // A runtime, an id that is not a Flatpak id, another kind of bundle: not offered.
    EXPECT_FALSE(find("org.example.Platform"));
    EXPECT_FALSE(find("notanid"));
    EXPECT_FALSE(find("org.example.Packaged"));

    // Our entry of source flatpak: our name, Flathub's ref; not installed; listed once.
    const StoreApp *flat = find("org.example.Flat");
    ASSERT_TRUE(flat);
    EXPECT_TRUE(flat->inCatalog);
    EXPECT_EQ(flat->name.en, QStringLiteral("Flat"));
    EXPECT_EQ(flat->flatpakRef, QStringLiteral("app/org.example.Flat/x86_64/stable"));
    EXPECT_EQ(flat->desktopId, QStringLiteral("org.example.Flat.desktop"));
    EXPECT_FALSE(flat->installed);
    EXPECT_EQ(std::count_if(apps.cbegin(), apps.cend(), [](const StoreApp &a) { return a.id == QLatin1String("org.example.Flat"); }), 1);

    // Flathub off: none of them.
    in.flathubOn = false;
    const QList<StoreApp> off = buildModel(in);
    EXPECT_TRUE(std::none_of(off.cbegin(), off.cend(), [](const StoreApp &a) { return a.source == CatalogSource::Kind::Flatpak; }));

    // A ref whose branch is not one (".."), or a ref of another app: neither listed nor offered to Get, ours hidden too.
    in.flathubOn = true;
    for (AppStreamComponent &c : in.flathub) {
        if (c.flatpak == QLatin1String("org.example.Flat"))
            c.flatpakRef = QStringLiteral("app/org.example.Flat/x86_64/..");
        if (c.flatpak == QLatin1String("org.example.Notes"))
            c.flatpakRef = QStringLiteral("app/org.example.Other/x86_64/stable");
    }
    const QList<StoreApp> bad = buildModel(in);
    EXPECT_TRUE(std::none_of(bad.cbegin(), bad.cend(), [](const StoreApp &a) {
        return a.id == QLatin1String("org.example.Flat") || a.id == QLatin1String("org.example.Notes") || a.id == QLatin1String("org.example.Other");
    }));
}
