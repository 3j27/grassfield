#include "storeview.h"

#include <QCollator>
#include <QDate>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUrl>

#include <algorithm>
#include <cmath>

namespace grassfield::store::view {

namespace {

QString fileUrl(const QString &path)
{
    return path.isEmpty() ? QString() : QUrl::fromLocalFile(path).toString();
}

CatalogCategory category(const char *id, const char *en, const char *fr, const char *symbol, QStringList freedesktop)
{
    CatalogCategory c;
    c.id = QString::fromLatin1(id);
    c.title = {QString::fromUtf8(en), QString::fromUtf8(fr)};
    c.symbol = QString::fromLatin1(symbol);
    c.freedesktop = std::move(freedesktop);
    return c;
}

double channel(double c)
{
    return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}

double luminance(const QColor &c)
{
    return 0.2126 * channel(c.redF()) + 0.7152 * channel(c.greenF()) + 0.0722 * channel(c.blueF());
}

// Desktop Entry "string" escapes: \s \n \t \r \\.
QString unescapeDesktop(const QString &value)
{
    QString out;
    for (int i = 0; i < value.size(); ++i) {
        const QChar c = value.at(i);
        if (c != QLatin1Char('\\') || i + 1 >= value.size()) {
            out += c;
            continue;
        }
        const QChar n = value.at(++i);
        out += n == QLatin1Char('s') ? QChar(u' ') : n == QLatin1Char('n') ? QChar(u'\n') : n == QLatin1Char('t') ? QChar(u'\t')
             : n == QLatin1Char('r') ? QChar(u'\r') : n;
    }
    return out;
}

// One Exec argument at the start of `text`: double-quoted (the backslash before " ` $ \ dropped) or bare up to a space;
// %% is a %. Empty when it does not parse.
QString execArgument(const QString &text, int *end)
{
    QString out;
    int i = 0;
    if (text.startsWith(QLatin1Char('"'))) {
        for (i = 1; i < text.size(); ++i) {
            const QChar c = text.at(i);
            if (c == QLatin1Char('"'))
                break;
            if (c == QLatin1Char('\\') && i + 1 < text.size())
                out += text.at(++i);
            else
                out += c;
        }
        if (i >= text.size())
            return {};
        ++i;
    } else {
        while (i < text.size() && !text.at(i).isSpace())
            out += text.at(i++);
    }
    *end = i;
    return out.replace(QStringLiteral("%%"), QStringLiteral("%"));
}

} // namespace

QString dayText(const QDate &date, const QLocale &locale, bool year)
{
    if (!date.isValid())
        return {};
    QString format = locale.dateFormat(QLocale::LongFormat);
    static const QRegularExpression weekday(QStringLiteral("dddd[,.]?\\s*"));
    format.remove(weekday);
    if (!year) // the day and the month in the locale's order: "October 27", « 27 octobre »
        format = format.indexOf(QLatin1Char('d')) < format.indexOf(QLatin1Char('M')) ? QStringLiteral("d MMMM") : QStringLiteral("MMMM d");
    return locale.toString(date, format.trimmed());
}

StoreApp aurApp(const AurPackage &package, bool installed, const QString &desktopId)
{
    StoreApp a;
    a.id = QStringLiteral("aur:") + package.name;
    a.source = CatalogSource::Kind::Aur;
    a.package = package.name;
    a.packages = {package.name};
    a.name.en = package.name;
    a.summary.en = package.description;
    a.description.en = package.description;
    a.license = package.licenses.join(QStringLiteral(", "));
    a.homepage = package.url;
    a.keywords = package.keywords;
    a.installed = installed;
    a.desktopId = installed ? desktopId : QString();
    return a;
}

QVariantMap aurFacts(const AurPackage &package, const QLocale &locale)
{
    QStringList depends;
    for (const QString &d : package.depends)
        depends.append(dependencyName(d));
    return {{QStringLiteral("version"), package.version},
            {QStringLiteral("maintainer"), package.maintainer},
            {QStringLiteral("orphaned"), package.orphaned},
            {QStringLiteral("votes"), package.votes},
            {QStringLiteral("popularity"), locale.toString(package.popularity, 'f', 2)},
            {QStringLiteral("lastModified"), dayText(package.lastModified.date(), locale)},
            {QStringLiteral("firstSubmitted"), dayText(package.firstSubmitted.date(), locale)},
            {QStringLiteral("outOfDate"), package.outOfDate.isValid()},
            {QStringLiteral("outOfDateSince"), dayText(package.outOfDate.date(), locale)},
            {QStringLiteral("base"), package.base},
            {QStringLiteral("keywords"), package.keywords},
            {QStringLiteral("optDepends"), package.optDepends},
            {QStringLiteral("depends"), depends}};
}

QString sizeText(qint64 bytes, const QLocale &locale)
{
    return bytes < 0 ? QString() : locale.formattedDataSize(bytes, 1, QLocale::DataSizeSIFormat);
}

QString sourceKind(CatalogSource::Kind kind)
{
    switch (kind) {
    case CatalogSource::Kind::Repo:
        return QStringLiteral("repo");
    case CatalogSource::Kind::Aur:
        return QStringLiteral("aur");
    case CatalogSource::Kind::OmarchySetup:
        return QStringLiteral("setup");
    case CatalogSource::Kind::WebApp:
        return QStringLiteral("webapp");
    case CatalogSource::Kind::Flatpak:
        return QStringLiteral("flatpak");
    }
    return QStringLiteral("repo");
}

QVariantMap summary(const StoreApp &app, const QString &language)
{
    return {{QStringLiteral("id"), app.id},
            {QStringLiteral("name"), app.name.pick(language)},
            {QStringLiteral("summary"), app.summary.pick(language)},
            {QStringLiteral("icon"), fileUrl(app.icon)},
            {QStringLiteral("kind"), sourceKind(app.source)},
            {QStringLiteral("repo"), app.repo},
            {QStringLiteral("installed"), app.installed},
            {QStringLiteral("launcher"), !app.desktopId.isEmpty()},
            // A Flatpak's app id (its data folder's name, ~/.var/app/<id>): its ref's second part.
            {QStringLiteral("flatpakId"), app.source == CatalogSource::Kind::Flatpak ? app.flatpakRef.section(QLatin1Char('/'), 1, 1) : QString()}};
}

QVariantMap detail(const StoreApp &app, const AppStreamComponent *component, const QList<CatalogCategory> &categories,
                   const QString &language, const QLocale &locale)
{
    QVariantMap out = summary(app, language);
    out.insert(QStringLiteral("description"), app.description.pick(language));
    out.insert(QStringLiteral("developer"), app.developer.pick(language));
    out.insert(QStringLiteral("license"), app.license);
    out.insert(QStringLiteral("homepage"), app.homepage);
    out.insert(QStringLiteral("package"), app.package);
    out.insert(QStringLiteral("packages"), app.packages);
    out.insert(QStringLiteral("desktopId"), app.desktopId);
    out.insert(QStringLiteral("inCatalog"), app.inCatalog);
    out.insert(QStringLiteral("screenshots"), app.screenshots);
    QStringList captions;
    if (component && component->screenshots == app.screenshots && component->screenshotCaptions.size() == app.screenshots.size())
        captions = component->screenshotCaptions;
    else
        captions = QStringList(app.screenshots.size(), QString());
    out.insert(QStringLiteral("captions"), captions);

    QStringList titles;
    for (const CatalogCategory &c : categories) {
        if (app.categories.contains(c.id))
            titles.append(c.title.pick(language));
    }
    out.insert(QStringLiteral("categories"), titles);

    QVariantList releases;
    QStringList languages;
    QVariantMap rating;
    bool rated = false;
    QString bugtracker;
    if (component) {
        for (const AppStreamRelease &r : component->releases) {
            releases.append(QVariantMap{{QStringLiteral("version"), r.version},
                                        {QStringLiteral("date"), dayText(QDate::fromString(r.date, Qt::ISODate), locale)},
                                        {QStringLiteral("notes"), r.description.pick(language)}});
        }
        for (const QString &code : component->languages) {
            const QLocale l(code);
            const QString name = l.language() == QLocale::C ? QString() : l.nativeLanguageName();
            if (!name.isEmpty() && !languages.contains(name))
                languages.append(name);
        }
        // A collator of our own: localeAwareCompare's shared default one is never freed (LeakSanitizer, ICU 78).
        const QCollator collator(locale);
        std::sort(languages.begin(), languages.end(), [&collator](const QString &a, const QString &b) {
            return collator.compare(a, b) < 0;
        });
        rated = component->rated;
        for (auto it = component->rating.cbegin(); it != component->rating.cend(); ++it)
            rating.insert(it.key(), it.value());
        bugtracker = component->bugtracker;
    }
    out.insert(QStringLiteral("releases"), releases);
    out.insert(QStringLiteral("languages"), languages);
    out.insert(QStringLiteral("rated"), rated);
    out.insert(QStringLiteral("rating"), rating);
    out.insert(QStringLiteral("bugtracker"), bugtracker);

    QVariantMap setup;
    QString webUrl, flatpakId;
    if (app.entry) {
        const CatalogSource &s = app.entry->source;
        if (s.kind == CatalogSource::Kind::OmarchySetup) {
            // The recipes as the terminal runs them: the name, then its arguments.
            setup = {{QStringLiteral("install"), (QStringList{s.install} + s.args).join(QLatin1Char(' '))},
                     {QStringLiteral("remove"), (QStringList{s.remove} + s.removeArgs).join(QLatin1Char(' '))},
                     {QStringLiteral("changes"), s.changes.pick(language)},
                     {QStringLiteral("removes"), s.removes.pick(language)}};
        } else if (s.kind == CatalogSource::Kind::WebApp) {
            webUrl = s.url;
        } else if (s.kind == CatalogSource::Kind::Flatpak) {
            flatpakId = s.flatpakId;
        }
    }
    if (app.source == CatalogSource::Kind::Flatpak && flatpakId.isEmpty())
        flatpakId = out.value(QStringLiteral("flatpakId")).toString(); // a Flathub app our catalog does not list: its ref's
    out.insert(QStringLiteral("setup"), setup);
    out.insert(QStringLiteral("webUrl"), webUrl);
    out.insert(QStringLiteral("flatpakId"), flatpakId);
    // A Flatpak's facts (SR11): its runtime as <id> <branch>, and Flathub's verified-developer flag.
    out.insert(QStringLiteral("runtime"), app.runtime.isEmpty() ? QString()
                                                                 : app.runtime.section(QLatin1Char('/'), 0, 0) + QLatin1Char(' ')
                                                                       + app.runtime.section(QLatin1Char('/'), 2, 2));
    out.insert(QStringLiteral("verified"), app.verified);
    return out;
}

QVariantMap packageFacts(const PackageInfo &info, const QLocale &locale)
{
    return {{QStringLiteral("name"), info.name},
            {QStringLiteral("repo"), info.repo},
            {QStringLiteral("version"), info.version},
            {QStringLiteral("downloadSize"), sizeText(info.downloadSize, locale)},
            {QStringLiteral("installedSize"), sizeText(info.installedSize, locale)},
            {QStringLiteral("buildDate"), dayText(info.buildDate, locale)},
            {QStringLiteral("licenses"), info.licenses.join(QStringLiteral(", "))}};
}

QList<CatalogCategory> builtInCategories()
{
    // grassfield-packages catalog/categories.json, the same order.
    return {
        category("productivity", "Productivity", "Productivité", "category-productivity",
                 {QStringLiteral("Office"), QStringLiteral("WordProcessor"), QStringLiteral("Spreadsheet"), QStringLiteral("Presentation"),
                  QStringLiteral("Calendar"), QStringLiteral("ContactManagement"), QStringLiteral("ProjectManagement")}),
        category("graphics", "Graphics", "Graphisme", "category-graphics",
                 {QStringLiteral("Graphics"), QStringLiteral("2DGraphics"), QStringLiteral("VectorGraphics"), QStringLiteral("RasterGraphics"),
                  QStringLiteral("3DGraphics"), QStringLiteral("Photography")}),
        category("photo-video", "Photos and Video", "Photos et vidéo", "category-photo-video",
                 {QStringLiteral("Video"), QStringLiteral("AudioVideoEditing"), QStringLiteral("Player"), QStringLiteral("TV")}),
        category("music-audio", "Music and Audio", "Musique et audio", "category-music-audio",
                 {QStringLiteral("Audio"), QStringLiteral("Music"), QStringLiteral("Midi"), QStringLiteral("Mixer"), QStringLiteral("Sequencer")}),
        category("developer-tools", "Development", "Développement", "category-developer-tools",
                 {QStringLiteral("Development"), QStringLiteral("IDE"), QStringLiteral("TextEditor"), QStringLiteral("Debugger"),
                  QStringLiteral("RevisionControl")}),
        category("games", "Games", "Jeux", "category-games", {QStringLiteral("Game")}),
        category("internet", "Internet", "Internet", "category-internet",
                 {QStringLiteral("Network"), QStringLiteral("WebBrowser"), QStringLiteral("Email"), QStringLiteral("Chat"),
                  QStringLiteral("InstantMessaging"), QStringLiteral("FileTransfer")}),
        category("education", "Education", "Éducation", "category-education",
                 {QStringLiteral("Education"), QStringLiteral("Science"), QStringLiteral("Math"), QStringLiteral("Languages")}),
        category("utilities", "Utilities", "Utilitaires", "category-utilities",
                 {QStringLiteral("Utility"), QStringLiteral("System"), QStringLiteral("Accessibility"), QStringLiteral("Archiving"),
                  QStringLiteral("Compression"), QStringLiteral("FileTools")}),
    };
}

QVariantList sections(const Catalog &catalog, const QList<StoreApp> &apps, const QHash<QString, int> &index,
                      const QHash<QString, QString> &heroTints, const QString &language)
{
    QVariantList out;
    for (const CatalogSection &section : catalog.sections) {
        QVariantList blocks;
        for (const CatalogBlock &block : section.blocks) {
            QVariantMap b;
            if (block.kind == CatalogBlock::Kind::Row) {
                QVariantList shown;
                for (const QString &id : block.apps) {
                    if (index.contains(id))
                        shown.append(summary(apps.at(index.value(id)), language));
                }
                if (shown.isEmpty())
                    continue;
                b = {{QStringLiteral("kind"), QStringLiteral("row")},
                     {QStringLiteral("title"), block.title.pick(language)},
                     {QStringLiteral("apps"), shown}};
            } else {
                QVariantList items;
                for (const CatalogItem &item : block.items) {
                    if (!index.contains(item.app))
                        continue;
                    items.append(QVariantMap{{QStringLiteral("app"), summary(apps.at(index.value(item.app)), language)},
                                             {QStringLiteral("eyebrow"), item.eyebrow.pick(language)},
                                             {QStringLiteral("title"), item.title.pick(language)},
                                             {QStringLiteral("text"), item.text.pick(language)},
                                             {QStringLiteral("tint"), heroTints.value(item.app)}});
                }
                if (items.isEmpty())
                    continue;
                b = {{QStringLiteral("kind"), block.kind == CatalogBlock::Kind::Hero ? QStringLiteral("hero") : QStringLiteral("cards")},
                     {QStringLiteral("items"), items}};
            }
            blocks.append(b);
        }
        if (blocks.isEmpty())
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), section.id},
                               {QStringLiteral("title"), section.title.pick(language)},
                               {QStringLiteral("symbol"), section.symbol},
                               {QStringLiteral("blocks"), blocks}});
    }
    return out;
}

QVariantMap builtInDiscover(const QList<StoreApp> &apps, const QList<CatalogCategory> &categories, const QString &language, int perRow)
{
    QVariantList blocks;
    for (const CatalogCategory &c : categories) {
        QList<const StoreApp *> in;
        for (const StoreApp &a : apps) {
            if (a.categories.contains(c.id))
                in.append(&a);
        }
        // The model is sorted by name: a stable partition keeps that order inside each half.
        std::stable_partition(in.begin(), in.end(), [](const StoreApp *a) { return !a->icon.isEmpty(); });
        QVariantList shown;
        for (const StoreApp *a : in) {
            if (shown.size() >= perRow)
                break;
            shown.append(summary(*a, language));
        }
        if (shown.isEmpty())
            continue;
        blocks.append(QVariantMap{{QStringLiteral("kind"), QStringLiteral("row")},
                                  {QStringLiteral("title"), c.title.pick(language)},
                                  {QStringLiteral("category"), c.id},
                                  {QStringLiteral("apps"), shown}});
    }
    return {{QStringLiteral("id"), QStringLiteral("discover")},
            {QStringLiteral("title"), QString()},
            {QStringLiteral("symbol"), QStringLiteral("discover")},
            {QStringLiteral("builtIn"), true},
            {QStringLiteral("blocks"), blocks}};
}

double contrast(const QColor &a, const QColor &b)
{
    const double la = luminance(a), lb = luminance(b);
    return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}

QColor heroTint(const QImage &icon, double minContrast)
{
    if (icon.isNull())
        return {};
    const QImage small = icon.convertToFormat(QImage::Format_ARGB32).scaled(24, 24, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    double r = 0, g = 0, b = 0, weight = 0;
    for (int y = 0; y < small.height(); ++y) {
        for (int x = 0; x < small.width(); ++x) {
            const QColor c = QColor::fromRgba(small.pixel(x, y));
            if (c.alpha() < 128 || c.hsvSaturationF() < 0.25 || c.valueF() < 0.2)
                continue; // transparent, grey, or nearly black: no colour of its own
            const double w = c.hsvSaturationF() * c.alphaF();
            r += c.redF() * w;
            g += c.greenF() * w;
            b += c.blueF() * w;
            weight += w;
        }
    }
    if (weight < 1.0) // fewer than a few coloured pixels: a grey or monochrome icon
        return {};
    QColor tint = QColor::fromRgbF(float(r / weight), float(g / weight), float(b / weight));
    const QColor white(Qt::white);
    for (int i = 0; i < 100 && contrast(tint, white) < minContrast; ++i) {
        float h, s, l;
        tint.getHslF(&h, &s, &l);
        tint = QColor::fromHslF(h, s, std::max(0.0f, l - 0.02f));
    }
    return tint;
}

std::optional<WebAppEntry> parseWebAppEntry(const QByteArray &desktopFile)
{
    if (desktopFile.size() > 64 * 1024)
        return std::nullopt;
    bool inEntry = false;
    QString name, exec, icon;
    for (const QString &raw : QString::fromUtf8(desktopFile).split(QLatin1Char('\n'))) {
        const QString line = raw.trimmed();
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = line == QLatin1String("[Desktop Entry]");
            continue;
        }
        if (!inEntry || line.startsWith(QLatin1Char('#')))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const QString key = line.left(eq).trimmed(), value = unescapeDesktop(line.mid(eq + 1).trimmed());
        if (key == QLatin1String("Name") && name.isEmpty())
            name = value;
        else if (key == QLatin1String("Exec"))
            exec = value;
        else if (key == QLatin1String("Icon"))
            icon = value;
    }
    static const QString launcher = QStringLiteral("omarchy-launch-webapp ");
    if (!exec.startsWith(launcher))
        return std::nullopt;
    const QString rest = exec.mid(launcher.size()).trimmed();
    int end = 0;
    const QString url = execArgument(rest, &end);
    if (url.isEmpty() || !rest.mid(end).trimmed().isEmpty())
        return std::nullopt; // a custom command line: not a plain web app
    const QUrl parsed(url, QUrl::StrictMode);
    if (!parsed.isValid() || (parsed.scheme() != QLatin1String("https") && parsed.scheme() != QLatin1String("http")) || parsed.host().isEmpty())
        return std::nullopt;
    const QString clean = cleanPlainText(name, 64, false);
    if (clean.isEmpty())
        return std::nullopt;
    return WebAppEntry{clean, url, icon, QString()};
}

QString initials(const QString &fullName)
{
    const QStringList words = fullName.simplified().split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (words.isEmpty())
        return {};
    const auto first = [](const QString &w) {
        const QList<uint> ucs = w.toUcs4();
        return ucs.isEmpty() ? QString() : QString::fromUcs4(reinterpret_cast<const char32_t *>(ucs.constData()), 1).toUpper();
    };
    return words.size() == 1 ? first(words.first()) : first(words.first()) + first(words.last());
}

QVariantMap updates(const QByteArray &json, const QList<StoreApp> &apps, const QString &language, const QLocale &locale)
{
    const QVariantMap unknown{{QStringLiteral("state"), QStringLiteral("unknown")}};
    if (json.isEmpty() || json.size() > 512 * 1024)
        return unknown;
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return unknown;
    const QJsonObject o = doc.object();
    if (o.value(QStringLiteral("version")).toInt() != 1 || !o.value(QStringLiteral("state")).isString())
        return unknown;
    static const QStringList states{QStringLiteral("not-set-up"), QStringLiteral("repair"), QStringLiteral("blocking"),
                                    QStringLiteral("up-to-date"), QStringLiteral("available"), QStringLiteral("failed"),
                                    QStringLiteral("update-running"), QStringLiteral("busy")};
    const QString state = o.value(QStringLiteral("state")).toString();
    if (!states.contains(state))
        return unknown;
    const auto when = [&](const char *key) {
        const QDateTime t = QDateTime::fromString(o.value(QLatin1String(key)).toString(), Qt::ISODate);
        return t.isValid() ? locale.toString(t.toLocalTime(), QLocale::ShortFormat) : QString();
    };
    const auto release = [&](const char *key) {
        const QJsonObject r = o.value(QLatin1String(key)).toObject();
        return QVariantMap{{QStringLiteral("installed"), cleanPlainText(r.value(QStringLiteral("installed")).toString(), 64, false)},
                           {QStringLiteral("available"), cleanPlainText(r.value(QStringLiteral("available")).toString(), 64, false)}};
    };
    QHash<QString, const StoreApp *> byPackage;
    for (const StoreApp &a : apps) {
        if (a.installed && a.source == CatalogSource::Kind::Repo && !a.package.isEmpty())
            byPackage.insert(a.package, &a);
    }
    QVariantList withUpdate;
    const QJsonArray others = o.value(QStringLiteral("otherPackages")).toArray();
    for (const QJsonValue &v : others) {
        const QJsonObject p = v.toObject();
        const StoreApp *a = byPackage.value(p.value(QStringLiteral("name")).toString());
        if (!a)
            continue;
        QVariantMap m = summary(*a, language);
        m.insert(QStringLiteral("from"), cleanPlainText(p.value(QStringLiteral("installed")).toString(), 64, false));
        m.insert(QStringLiteral("to"), cleanPlainText(p.value(QStringLiteral("available")).toString(), 64, false));
        withUpdate.append(m);
    }
    const int count = std::max(0, o.value(QStringLiteral("others")).toInt());
    return {{QStringLiteral("state"), state},
            {QStringLiteral("error"), o.value(QStringLiteral("error")).toString()},
            {QStringLiteral("checkedAt"), when("checkedAt")},
            {QStringLiteral("lastSuccessAt"), when("lastSuccessAt")},
            {QStringLiteral("grassfield"), release("grassfield")},
            {QStringLiteral("omarchy"), release("omarchy")},
            {QStringLiteral("others"), count},
            {QStringLiteral("listed"), o.contains(QStringLiteral("otherPackages"))},
            {QStringLiteral("truncated"), o.value(QStringLiteral("otherPackagesTruncated")).toBool()},
            {QStringLiteral("apps"), withUpdate},
            // The other updates the list names that are not apps (the "N other system packages" line).
            {QStringLiteral("otherCount"), std::max(0, count - int(withUpdate.size()))}};
}

} // namespace grassfield::store::view
