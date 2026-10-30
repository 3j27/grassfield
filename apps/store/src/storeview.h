// What the Store's QML shows (spec SR1-SR12, SR23, SR24), made from the merged model: plain values in QVariantMaps, the words
// left to the QML (qsTr): a source is a kind and a repository, a rating its groups and levels. Pure: no file, no process, no
// network, except heroTint, which reads the icon file it is given.
#pragma once

#include "appstream.h"
#include "aur.h"
#include "catalog.h"
#include "pacman.h"
#include "storemodel.h"

#include <QColor>
#include <QDate>
#include <QHash>
#include <QImage>
#include <QList>
#include <QLocale>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#include <optional>

namespace grassfield::store::view {

// "repo", "aur", "setup", "webapp" or "flatpak".
QString sourceKind(CatalogSource::Kind kind);

// A size as `locale` writes it ("12.4 MB", « 12,4 Mo »); "" for a negative one.
QString sizeText(qint64 bytes, const QLocale &locale);

// A day as the locale writes it in full, without the weekday ("October 27, 2026", « 27 octobre 2026 »); without the year
// when `year` is false ("October 27", « 27 octobre »). "" for an invalid date.
QString dayText(const QDate &date, const QLocale &locale, bool year = true);

// A card's, a list item's or a result's: id, name, summary, icon (a file URL or ""), kind, repo, installed, launcher, and a
// Flatpak's app id (flatpakId, "" for the others).
QVariantMap summary(const StoreApp &app, const QString &language);

// The product page's (SR9-SR12): the summary and description, developer, licence, homepage, bugtracker, screenshots and
// their captions, releases (version, day as `locale` writes it, notes), languages (their own names, sorted), rating
// (rated, and the level of each OARS group), categories (titles), packages, repository, desktop id, and for a setup its
// recipe and our texts, for a web app its address, for a Flatpak its app id, runtime ("org.gnome.Platform 50") and Flathub's
// verified flag. `component` may be null (no AppStream data).
QVariantMap detail(const StoreApp &app, const AppStreamComponent *component, const QList<CatalogCategory> &categories,
                   const QString &language, const QLocale &locale);

// pacman -Si's facts for the Information list: version, the sizes and the build day as `locale` writes them.
QVariantMap packageFacts(const PackageInfo &info, const QLocale &locale);

// An AUR package as the Store shows it (step 3b2; spec SR7, SR11): its page's id is "aur:<name>", its name the package's,
// its summary the AUR's description, its licence the AUR's list. `installed`: pacman has it from outside the repositories;
// `desktopId`: its first application entry, for Open.
StoreApp aurApp(const AurPackage &package, bool installed, const QString &desktopId);
// The AUR's facts for the Information list and the search results: version, maintainer ("" and orphaned), votes,
// popularity (two decimals as `locale` writes them), last updated and first submitted (days), outOfDate (bool) and its day,
// the package base, keywords, optional dependencies, and the dependencies by name.
QVariantMap aurFacts(const AurPackage &package, const QLocale &locale);

// The categories used while there is no catalog: the same ids, names and freedesktop lists as grassfield-packages'
// catalog/categories.json, so an app is placed the same way with or without it.
QList<CatalogCategory> builtInCategories();

// The catalog's sections for QML, in its order: id, title, symbol, blocks (hero and cards: items with their app's summary,
// eyebrow, title, text and the hero's tint; row: title and its apps' summaries). An item or app the model does not offer
// (hidden: its source lacks the package, or its source is off) is left out, and so is a block or a section left empty.
// heroTints: the tint of an app's hero card, by app id ("" when its icon gave none).
QVariantList sections(const Catalog &catalog, const QList<StoreApp> &apps, const QHash<QString, int> &index,
                      const QHash<QString, QString> &heroTints, const QString &language);

// Discover without the catalog's (SR2): one row per category that has apps, apps with an icon first, then by name; at most
// `perRow` in each.
QVariantMap builtInDiscover(const QList<StoreApp> &apps, const QList<CatalogCategory> &categories, const QString &language,
                            int perRow = 12);

// The tint behind an app's icon on a hero card: the icon's most saturated colours averaged, darkened until white text on it
// holds `minContrast` (A2: the tint is darkened, never the text lightened). Invalid when the image has no colour to give.
QColor heroTint(const QImage &icon, double minContrast = 4.5);
// WCAG 2 contrast ratio of two opaque colours.
double contrast(const QColor &a, const QColor &b);

// An Omarchy web app's launcher (~/.local/share/applications/*.desktop whose Exec is `omarchy-launch-webapp <url>`).
struct WebAppEntry {
    QString name;
    QString url;
    QString icon; // an absolute file path, or ""
    QString file; // its file's name without ".desktop" (what omarchy-webapp-remove takes), set by the folder's reader
};
std::optional<WebAppEntry> parseWebAppEntry(const QByteArray &desktopFile);

// The initials of a full name for the account circle: the first letter of the first and the last word, upper case.
QString initials(const QString &fullName);

// software-update.json (ADR-0033 d.7, version 1) for the read-only Updates list: state, checkedAt and lastSuccessAt (as
// `locale` writes them), the Grassfield and Omarchy releases (installed, available), others (the count), and apps: the
// installed apps the list of other updates names (otherPackages, Software Update's step 2), each with its versions; an
// unreadable file or another version gives {state: "unknown"}.
QVariantMap updates(const QByteArray &json, const QList<StoreApp> &apps, const QString &language, const QLocale &locale);

} // namespace grassfield::store::view
