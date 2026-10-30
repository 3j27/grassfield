#include "storemodel.h"

#include "flatpak.h"

#include <QFileInfo>

#include <algorithm>

namespace grassfield::store {

namespace {

// Lower case, accents removed, for matching only.
QString fold(const QString &text)
{
    const QString decomposed = text.normalized(QString::NormalizationForm_KD).toCaseFolded();
    QString out;
    out.reserve(decomposed.size());
    for (const QChar c : decomposed) {
        if (c.category() != QChar::Mark_NonSpacing)
            out += c;
    }
    return out;
}

QString iconFile(const QString &root, const AppStreamComponent &c)
{
    if (c.cachedIcon.isEmpty() || c.origin.isEmpty() || c.origin.contains(QLatin1Char('/')) || c.origin.startsWith(QLatin1Char('.')))
        return {};
    const QString path = root + QStringLiteral("/icons/") + c.origin + QLatin1Char('/') + c.cachedIcon;
    if (QFileInfo::exists(path))
        return path;
    // Arch's data ships its cached icons as JPEG XL whatever the XML names (S3).
    const QString jxl = path.section(QLatin1Char('.'), 0, -2) + QStringLiteral(".jxl");
    return QFileInfo::exists(jxl) ? jxl : QString();
}

// Flathub's icons are <root>/icons/<width>x<height>/<file> (S21), the AppStream's cached icon.
QString flathubIcon(const QString &root, const AppStreamComponent &c)
{
    if (c.cachedIcon.isEmpty() || root.isEmpty())
        return {};
    const QString path = root + QStringLiteral("/icons/") + c.cachedIcon;
    return QFileInfo::exists(path) ? path : QString();
}

// A Flathub component the Store can install: a bundle whose ref is an app's, of the app id it names.
bool installableFlatpak(const AppStreamComponent &c)
{
    return isFlatpakAppRef(c.flatpakRef) && flatpakRefId(c.flatpakRef) == c.flatpak;
}

QStringList mapCategories(const QStringList &freedesktop, const Catalog *catalog)
{
    QStringList out;
    if (!catalog)
        return out;
    for (const CatalogCategory &c : catalog->categories) {
        for (const QString &f : freedesktop) {
            if (c.freedesktop.contains(f)) {
                out.append(c.id);
                break;
            }
        }
    }
    return out;
}

LocalizedText prefer(const LocalizedText &ours, const LocalizedText &theirs)
{
    return ours.isEmpty() ? theirs : ours;
}

} // namespace

QList<StoreApp> buildModel(const ModelInputs &in)
{
    QHash<QString, SyncPackage> sync; // by name, from the repositories the Store offers only
    for (const SyncPackage &p : in.sync) {
        if (isStoreRepository(p.repo) && !sync.contains(p.name))
            sync.insert(p.name, p); // pacman's order: the first repository that has it wins, as for pacman -S
    }
    QHash<QString, int> byId; // index into in.appstream
    for (int i = 0; i < in.appstream.size(); ++i) {
        const AppStreamComponent &c = in.appstream.at(i);
        if (c.type == QLatin1String("desktop-application") && !byId.contains(c.id))
            byId.insert(c.id, i);
    }
    QHash<QString, int> byFlatpak; // index into in.flathub, by app id
    for (int i = 0; in.flathubOn && i < in.flathub.size(); ++i) {
        const AppStreamComponent &c = in.flathub.at(i);
        if (installableFlatpak(c) && !byFlatpak.contains(c.flatpak))
            byFlatpak.insert(c.flatpak, i);
    }

    QList<StoreApp> apps;
    QSet<QString> listedIds, listedPackages;
    if (in.catalog) {
        for (const CatalogApp &e : in.catalog->apps) {
            // Listed even when hidden below: AppStream never offers an app our catalog pinned to a source that lacks it.
            listedIds.insert(e.id);
            StoreApp a;
            a.id = e.id;
            a.source = e.source.kind;
            a.inCatalog = true;
            a.entry = &e;
            switch (e.source.kind) {
            case CatalogSource::Kind::Repo: {
                const auto it = sync.constFind(e.source.package);
                if (it == sync.constEnd() || it->repo != e.source.repo)
                    continue; // pacman's database has no such package there: hidden
                a.repo = e.source.repo;
                a.package = e.source.package;
                a.packages = {a.package};
                a.installed = it->installed;
                break;
            }
            case CatalogSource::Kind::OmarchySetup: {
                bool all = true, installed = true;
                for (const QString &p : e.source.packages) {
                    const auto it = sync.constFind(p);
                    all = all && it != sync.constEnd();
                    installed = installed && it != sync.constEnd() && it->installed;
                }
                if (!all)
                    continue;
                a.packages = e.source.packages;
                a.installed = installed;
                break;
            }
            case CatalogSource::Kind::Aur:
                // A repository's package of that name is not the AUR's (yay would take it): such an entry is hidden.
                if (!in.aurOn || sync.contains(e.source.package))
                    continue;
                a.package = e.source.package;
                a.packages = {a.package};
                a.installed = in.foreign.contains(a.package);
                break;
            case CatalogSource::Kind::Flatpak:
                // Flathub's data or nothing: an app Flathub does not have (or its AppStream not there yet) is hidden.
                if (!in.flathubOn || !byFlatpak.contains(e.source.flatpakId))
                    continue;
                listedIds.insert(e.source.flatpakId);
                a.installed = in.flatpaks.contains(e.source.flatpakId);
                break;
            case CatalogSource::Kind::WebApp:
                break;
            }
            // AppStream's data only for the package this entry installs: an id alone could lend an entry another package's
            // texts and desktop id, and step 3 would open the wrong app (web apps and Flatpaks have no Arch package).
            const bool flatpak = e.source.kind == CatalogSource::Kind::Flatpak;
            const int found = flatpak ? byFlatpak.value(e.source.flatpakId) : byId.value(e.id, -1);
            const AppStreamComponent *c = found < 0 ? nullptr : flatpak ? &in.flathub.at(found) : &in.appstream.at(found);
            if (c && !flatpak && !a.packages.contains(c->pkgname))
                c = nullptr;
            a.hasAppStream = c != nullptr;
            a.component = c ? found : -1;
            a.name = prefer(e.name, c ? c->name : LocalizedText{});
            a.summary = prefer(e.summary, c ? c->summary : LocalizedText{});
            a.description = prefer(e.description, c ? c->description : LocalizedText{});
            a.developer = prefer(e.developer, c ? c->developer : LocalizedText{});
            a.license = c && !c->license.isEmpty() ? c->license : e.license;
            a.homepage = !e.homepage.isEmpty() ? e.homepage : (c ? c->homepage : QString());
            a.desktopId = !e.desktopId.isEmpty() ? e.desktopId : (c ? c->desktopId : QString());
            a.icon = !c ? QString() : flatpak ? flathubIcon(in.flathubRoot, *c) : iconFile(in.appstreamRoot, *c);
            if (flatpak) {
                a.flatpakRef = c->flatpakRef;
                a.runtime = c->runtime;
                a.verified = c->verified;
                if (a.desktopId.isEmpty())
                    a.desktopId = e.source.flatpakId + QStringLiteral(".desktop"); // flatpak exports it by the app id
            }
            if (a.icon.isEmpty() && !c && e.icon && in.catalogIcon)
                a.icon = in.catalogIcon(*e.icon);
            a.screenshots = c ? c->screenshots : QStringList{};
            a.keywords = c ? c->keywords : QStringList{};
            a.categories = !e.categories.isEmpty() ? e.categories : mapCategories(c ? c->categories : QStringList{}, in.catalog);
            if (a.name.isEmpty())
                a.name.en = a.package.isEmpty() ? a.id : a.package;
            listedIds.insert(a.id);
            for (const QString &p : a.packages)
                listedPackages.insert(p);
            apps.append(a);
        }
    }
    for (int i = 0; i < in.appstream.size(); ++i) {
        const AppStreamComponent &c = in.appstream.at(i);
        if (c.type != QLatin1String("desktop-application") || listedIds.contains(c.id) || listedPackages.contains(c.pkgname))
            continue;
        const auto it = sync.constFind(c.pkgname);
        if (it == sync.constEnd())
            continue;
        StoreApp a;
        a.id = c.id;
        a.repo = it->repo;
        a.package = c.pkgname;
        a.packages = {c.pkgname};
        a.installed = it->installed;
        a.hasAppStream = true;
        a.component = i;
        a.name = c.name.isEmpty() ? LocalizedText{c.pkgname, {}} : c.name;
        a.summary = c.summary;
        a.description = c.description;
        a.developer = c.developer;
        a.license = c.license;
        a.homepage = c.homepage;
        a.desktopId = c.desktopId;
        a.icon = iconFile(in.appstreamRoot, c);
        a.screenshots = c.screenshots;
        a.keywords = c.keywords;
        a.categories = mapCategories(c.categories, in.catalog);
        listedIds.insert(a.id);
        listedPackages.insert(c.pkgname);
        apps.append(a);
    }
    // Flathub's desktop applications neither our catalog nor Arch's AppStream has (Arch names some by their entry's file,
    // "<id>.desktop": the same app).
    for (int i = 0; in.flathubOn && i < in.flathub.size(); ++i) {
        const AppStreamComponent &c = in.flathub.at(i);
        if (c.type != QLatin1String("desktop-application") || !installableFlatpak(c) || byFlatpak.value(c.flatpak) != i
            || listedIds.contains(c.id) || listedIds.contains(c.flatpak) || listedIds.contains(c.flatpak + QStringLiteral(".desktop")))
            continue;
        StoreApp a;
        a.id = c.flatpak;
        a.source = CatalogSource::Kind::Flatpak;
        a.installed = in.flatpaks.contains(c.flatpak);
        a.hasAppStream = true;
        a.component = i;
        a.name = c.name.isEmpty() ? LocalizedText{c.flatpak, {}} : c.name;
        a.summary = c.summary;
        a.description = c.description;
        a.developer = c.developer;
        a.license = c.license;
        a.homepage = c.homepage;
        a.desktopId = c.desktopId.isEmpty() ? c.flatpak + QStringLiteral(".desktop") : c.desktopId;
        a.flatpakRef = c.flatpakRef;
        a.runtime = c.runtime;
        a.verified = c.verified;
        a.icon = flathubIcon(in.flathubRoot, c);
        a.screenshots = c.screenshots;
        a.keywords = c.keywords;
        a.categories = mapCategories(c.categories, in.catalog);
        listedIds.insert(a.id);
        listedIds.insert(c.id);
        apps.append(a);
    }
    std::stable_sort(apps.begin(), apps.end(), [](const StoreApp &x, const StoreApp &y) {
        return fold(x.name.en).compare(fold(y.name.en)) < 0;
    });
    return apps;
}

QList<int> searchApps(const QList<StoreApp> &apps, const QString &query, const QString &language, int limit)
{
    const QString q = fold(query.simplified());
    if (q.isEmpty())
        return {};
    QList<QPair<int, int>> ranked; // rank, index
    for (int i = 0; i < apps.size(); ++i) {
        const StoreApp &a = apps.at(i);
        const QString name = fold(a.name.pick(language));
        int rank = -1;
        if (name.startsWith(q))
            rank = 0;
        else if (name.contains(QLatin1Char(' ') + q))
            rank = 1;
        else if (name.contains(q))
            rank = 2;
        else if (std::any_of(a.keywords.begin(), a.keywords.end(), [&](const QString &k) { return fold(k).startsWith(q); }))
            rank = 3;
        else if (fold(a.summary.pick(language)).contains(q))
            rank = 4;
        else if (a.package.contains(q) || std::any_of(a.packages.begin(), a.packages.end(), [&](const QString &p) { return p.contains(q); }))
            rank = 5;
        if (rank >= 0)
            ranked.append({rank, i});
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const auto &x, const auto &y) { return x.first < y.first; });
    QList<int> out;
    for (const auto &r : ranked) {
        if (out.size() >= limit)
            break;
        out.append(r.second);
    }
    return out;
}

QList<int> appsInCategory(const QList<StoreApp> &apps, const QString &categoryId)
{
    QList<int> out;
    for (int i = 0; i < apps.size(); ++i) {
        if (apps.at(i).categories.contains(categoryId))
            out.append(i);
    }
    return out;
}

} // namespace grassfield::store
