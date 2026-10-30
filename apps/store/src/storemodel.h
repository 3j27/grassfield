// The apps the Store shows (ADR-0037 a, c; spec SR5-SR8): our catalog's entries merged with Arch's AppStream and pacman's
// databases, plus the AppStream desktop applications our catalog does not list. Pure: the inputs are read elsewhere.
//   - a catalog entry overlays AppStream's component of the same id: our name, summary, description and developer win;
//     AppStream's icon wins over ours (ST10: a publisher's icon only for an app without metadata); the licence is
//     AppStream's when it states one, else ours (the package's own licence comes with its product page, pacman -Si);
//   - a repository app is shown only when pacman's database has its package in that repository; a setup only when it has
//     every one of its packages; AUR and Flathub entries only while their source is on (owner ST2);
//   - an AppStream component is offered alone only when it is a desktop application whose package is in a repository the
//     Store offers (SD1: the Store installs from the repositories only apps it can remove again), and our catalog does not
//     list its id (an entry hidden because its pinned source lacks the package stays hidden);
//   - while Flathub is on (step 3c), a desktop application of Flathub's AppStream (the user's installation's copy) is offered
//     when neither our catalog nor Arch's AppStream has its id (an app in several sources shows the first of: setup,
//     repository, Flathub, AUR; ADR-0037 a); a catalog entry of source flatpak takes its Flathub data, and is hidden when
//     Flathub has no such app.
#pragma once

#include "appstream.h"
#include "catalog.h"
#include "pacman.h"

#include <QHash>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>

#include <functional>

namespace grassfield::store {

struct StoreApp {
    QString id;
    CatalogSource::Kind source = CatalogSource::Kind::Repo;
    QString repo;          // Repo
    QString package;       // Repo, Aur
    QStringList packages;  // OmarchySetup: its packages; Repo: the one package
    LocalizedText name, summary, description, developer;
    QString license;
    QString homepage;
    QString desktopId;
    QString flatpakRef;    // Flatpak: app/<id>/<arch>/<branch>, as Flathub's AppStream names it
    QString runtime;       // Flatpak: the runtime that ref needs, <id>/<arch>/<branch>
    bool verified = false; // Flatpak: Flathub's verified-developer flag
    QString icon;          // a local file, or "" (the generic glyph)
    QStringList screenshots;
    QStringList categories; // our catalog's category ids
    QStringList keywords;
    bool installed = false;
    bool inCatalog = false;
    bool hasAppStream = false;
    // Its AppStream component: an index into ModelInputs::appstream, or ModelInputs::flathub for a Flatpak; -1 for none.
    int component = -1;
    const CatalogApp *entry = nullptr; // the catalog entry, when there is one (owned by the Catalog)
};

struct ModelInputs {
    const Catalog *catalog = nullptr; // may be null: no catalog yet (first start offline, or no hosting)
    QList<AppStreamComponent> appstream;
    QString appstreamRoot; // the swcatalog folder its cached icons are under
    QList<SyncPackage> sync;
    QSet<QString> foreign; // the packages installed from outside the repositories (an AUR app is installed when there)
    bool aurOn = false;
    bool flathubOn = false;
    QList<AppStreamComponent> flathub; // Flathub's AppStream (its components with a Flatpak bundle)
    QString flathubRoot;               // its folder: icons/<width>x<height>/<file>
    QSet<QString> flatpaks;            // the apps of the user's installation (flatpak list --user --app)
    // The cached file of a catalog icon, "" when it is not cached (catalogstore.h).
    std::function<QString(const CatalogIcon &)> catalogIcon;
};

QList<StoreApp> buildModel(const ModelInputs &in);

// The local search (SR6): name, keywords, summary and package name; name prefixes first. Case and accents are ignored.
// Returns indexes into `apps`, best first, at most `limit`.
QList<int> searchApps(const QList<StoreApp> &apps, const QString &query, const QString &language, int limit = 200);

// The apps of one of our categories: its own entries, and AppStream apps whose freedesktop categories it gathers.
QList<int> appsInCategory(const QList<StoreApp> &apps, const QString &categoryId);

} // namespace grassfield::store
