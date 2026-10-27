#include "catalog.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QRegularExpression>
#include <QSet>

#include <cmath>
#include <functional>

namespace grassfield::store {

namespace {

// Lengths in code points (ADR-0037 g).
constexpr int kLenSectionTitle = 40, kLenEyebrow = 40, kLenTitle = 80, kLenText = 200, kLenDescription = 4000;

bool matches(const QString &value, const char *pattern)
{
    const QRegularExpression re(QString::fromLatin1(pattern));
    return re.match(value).hasMatch();
}

bool isBidiControl(char32_t c)
{
    return c == 0x061C || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069);
}

// One localized object, or nothing when absent; `problem` is set when it is present and breaks the rule.
std::optional<LocalizedText> localized(const QJsonValue &value, int limit, bool lineFeeds, QString *problem)
{
    if (value.isUndefined())
        return std::nullopt;
    if (!value.isObject()) {
        *problem = QStringLiteral("not an object like {\"en\": \"…\"}");
        return std::nullopt;
    }
    const QJsonObject o = value.toObject();
    if (!o.value(QStringLiteral("en")).isString()) {
        *problem = QStringLiteral("no English text");
        return std::nullopt;
    }
    LocalizedText text;
    for (const char *lang : {"en", "fr"}) {
        const QJsonValue v = o.value(QLatin1String(lang));
        if (v.isUndefined())
            continue;
        const QString s = v.toString();
        const QString why = v.isString() ? plainTextProblem(s, limit, lineFeeds) : QStringLiteral("not a string");
        if (!why.isEmpty()) {
            *problem = QLatin1String(lang) + QStringLiteral(": ") + why;
            return std::nullopt;
        }
        (QLatin1String(lang) == QLatin1String("en") ? text.en : text.fr) = s;
    }
    return text; // other languages are ignored by v1
}

// A required localized text: false (and `problem`) when absent or broken.
bool requiredText(const QJsonObject &o, const char *key, int limit, bool lineFeeds, LocalizedText *out, QString *problem)
{
    QString why;
    const auto text = localized(o.value(QLatin1String(key)), limit, lineFeeds, &why);
    if (!text) {
        *problem = QLatin1String(key) + QStringLiteral(": ") + (why.isEmpty() ? QStringLiteral("missing") : why);
        return false;
    }
    *out = *text;
    return true;
}

// An optional localized text: false (and `problem`) only when present and broken.
bool optionalText(const QJsonObject &o, const char *key, int limit, bool lineFeeds, LocalizedText *out, QString *problem)
{
    QString why;
    const auto text = localized(o.value(QLatin1String(key)), limit, lineFeeds, &why);
    if (!why.isEmpty()) {
        *problem = QLatin1String(key) + QStringLiteral(": ") + why;
        return false;
    }
    if (text)
        *out = *text;
    return true;
}

bool stringList(const QJsonValue &value, int min, int max, const std::function<bool(const QString &)> &ok, QStringList *out)
{
    if (value.isUndefined() && min == 0) {
        out->clear();
        return true;
    }
    if (!value.isArray())
        return false;
    const QJsonArray a = value.toArray();
    if (a.size() < min || a.size() > max)
        return false;
    QStringList list;
    for (const QJsonValue &v : a) {
        if (!v.isString() || !ok(v.toString()))
            return false;
        list.append(v.toString());
    }
    *out = list;
    return true;
}

bool isLicense(const QString &s)
{
    return s.size() <= 128 && matches(s, R"(\A[A-Za-z0-9.+()-]+( (AND|OR|WITH) [A-Za-z0-9.+()-]+)*\z)");
}

bool isSymbol(const QString &s)
{
    return matches(s, R"(\A[a-z][a-z0-9-]{0,47}\z)");
}

bool isSectionId(const QString &s)
{
    return matches(s, R"(\A[a-z][a-z0-9-]{0,31}\z)");
}

std::optional<CatalogSource> parseSource(const QJsonValue &value, QString *problem)
{
    if (!value.isObject()) {
        *problem = QStringLiteral("source: missing");
        return std::nullopt;
    }
    const QJsonObject o = value.toObject();
    const QString kind = o.value(QStringLiteral("kind")).toString();
    CatalogSource s;
    auto str = [&](const char *key) { return o.value(QLatin1String(key)).toString(); };
    if (kind == QLatin1String("repo")) {
        s.kind = CatalogSource::Kind::Repo;
        s.repo = str("repo");
        s.package = str("package");
        if (!QStringList{QStringLiteral("core"), QStringLiteral("extra"), QStringLiteral("multilib"), QStringLiteral("omarchy")}.contains(s.repo)
            || !isPackageName(s.package)) {
            *problem = QStringLiteral("source: repo or package");
            return std::nullopt;
        }
    } else if (kind == QLatin1String("aur")) {
        s.kind = CatalogSource::Kind::Aur;
        s.package = str("package");
        if (!isPackageName(s.package)) {
            *problem = QStringLiteral("source: package");
            return std::nullopt;
        }
    } else if (kind == QLatin1String("omarchy-setup")) {
        s.kind = CatalogSource::Kind::OmarchySetup;
        s.install = str("install");
        s.remove = str("remove");
        const auto arg = [](const QString &a) { return matches(a, R"(\A[a-z0-9][a-z0-9.-]{0,63}\z)"); };
        if (!matches(s.install, R"(\Aomarchy-install-[a-z0-9-]+\z)") || !matches(s.remove, R"(\Aomarchy-remove-[a-z0-9-]+\z)")
            || !stringList(o.value(QStringLiteral("args")), 0, 4, arg, &s.args)
            || !stringList(o.value(QStringLiteral("removeArgs")), 0, 4, arg, &s.removeArgs)
            || !stringList(o.value(QStringLiteral("packages")), 1, 16, isPackageName, &s.packages)) {
            *problem = QStringLiteral("source: a setup's recipes, arguments or packages");
            return std::nullopt;
        }
        QString why;
        if (!requiredText(o, "changes", kLenText, true, &s.changes, &why) || !optionalText(o, "removes", kLenText, true, &s.removes, &why)) {
            *problem = QStringLiteral("source.") + why;
            return std::nullopt;
        }
    } else if (kind == QLatin1String("webapp")) {
        s.kind = CatalogSource::Kind::WebApp;
        s.url = str("url");
        if (!isHttpsUrl(s.url)) {
            *problem = QStringLiteral("source: url");
            return std::nullopt;
        }
    } else if (kind == QLatin1String("flatpak")) {
        s.kind = CatalogSource::Kind::Flatpak;
        s.flatpakId = str("app");
        if (str("remote") != QLatin1String("flathub") || !isFlatpakId(s.flatpakId)) {
            *problem = QStringLiteral("source: remote or app");
            return std::nullopt;
        }
    } else {
        *problem = QStringLiteral("source: unknown kind");
        return std::nullopt;
    }
    return s;
}

std::optional<CatalogApp> parseApp(const QJsonValue &value, const QSet<QString> &categoryIds, QString *problem)
{
    if (!value.isObject()) {
        *problem = QStringLiteral("not an object");
        return std::nullopt;
    }
    const QJsonObject o = value.toObject();
    CatalogApp app;
    app.id = o.value(QStringLiteral("id")).toString();
    if (!isAppId(app.id)) {
        *problem = QStringLiteral("id");
        return std::nullopt;
    }
    const auto source = parseSource(o.value(QStringLiteral("source")), problem);
    if (!source)
        return std::nullopt;
    app.source = *source;
    const bool webApp = app.source.kind == CatalogSource::Kind::WebApp;
    if (webApp ? !requiredText(o, "name", kLenTitle, false, &app.name, problem) : !optionalText(o, "name", kLenTitle, false, &app.name, problem))
        return std::nullopt;
    // Omarchy's installer makes a file of a web app's name (e.5, S9): every language's name must be one.
    if (webApp && (!isWebAppName(app.name.en) || (!app.name.fr.isEmpty() && !isWebAppName(app.name.fr)))) {
        *problem = QStringLiteral("name: not a web app name (1 to 64 characters, no '/', not starting with '.')");
        return std::nullopt;
    }
    if (!optionalText(o, "summary", kLenText, false, &app.summary, problem)
        || !optionalText(o, "description", kLenDescription, true, &app.description, problem)
        || !optionalText(o, "developer", kLenTitle, false, &app.developer, problem))
        return std::nullopt;
    const QJsonValue license = o.value(QStringLiteral("license"));
    if (!license.isUndefined()) {
        if (!license.isString() || !isLicense(license.toString())) {
            *problem = QStringLiteral("license");
            return std::nullopt;
        }
        app.license = license.toString();
    }
    const QJsonValue homepage = o.value(QStringLiteral("homepage"));
    if (!homepage.isUndefined()) {
        if (!isHttpsUrl(homepage.toString())) {
            *problem = QStringLiteral("homepage");
            return std::nullopt;
        }
        app.homepage = homepage.toString();
    }
    const QJsonValue desktopId = o.value(QStringLiteral("desktopId"));
    if (!desktopId.isUndefined()) {
        if (!isDesktopId(desktopId.toString())) {
            *problem = QStringLiteral("desktopId");
            return std::nullopt;
        }
        app.desktopId = desktopId.toString();
    }
    const QJsonValue icon = o.value(QStringLiteral("icon"));
    if (!icon.isUndefined()) {
        const QJsonObject i = icon.toObject();
        CatalogIcon ci;
        ci.sha256 = i.value(QStringLiteral("sha256")).toString();
        const QJsonValue bytes = i.value(QStringLiteral("bytes"));
        ci.bytes = bytes.isDouble() && bytes.toDouble() == std::floor(bytes.toDouble()) ? bytes.toInteger() : 0;
        ci.license = i.value(QStringLiteral("license")).toString();
        ci.origin = i.value(QStringLiteral("origin")).toString();
        if (!icon.isObject() || !matches(ci.sha256, R"(\A[0-9a-f]{64}\z)") || ci.bytes < 1 || ci.bytes > kIconMaxBytes
            || !isLicense(ci.license) || !isHttpsUrl(ci.origin)) {
            *problem = QStringLiteral("icon");
            return std::nullopt;
        }
        app.icon = ci;
    } else if (webApp) {
        *problem = QStringLiteral("a web app without an icon");
        return std::nullopt;
    }
    const QJsonValue cats = o.value(QStringLiteral("categories"));
    if (!cats.isUndefined()
        && !stringList(cats, 1, 4, [&](const QString &c) { return categoryIds.contains(c); }, &app.categories)) {
        *problem = QStringLiteral("categories");
        return std::nullopt;
    }
    return app;
}

} // namespace

QString LocalizedText::pick(const QString &language) const
{
    return language.startsWith(QLatin1String("fr")) && !fr.isEmpty() ? fr : en;
}

QString plainTextProblem(const QString &text, int limit, bool lineFeeds)
{
    if (text.isEmpty() || text != text.trimmed())
        return QStringLiteral("empty, or space at an end");
    const QList<uint> codePoints = text.toUcs4();
    if (codePoints.size() > limit)
        return QStringLiteral("longer than %1 characters").arg(limit);
    for (const uint c : codePoints) {
        if (c == '\n' && lineFeeds)
            continue;
        // Cc: controls; Cf: format characters (bidirectional controls, zero-width characters, the BOM, soft hyphens);
        // Zl, Zp: line and paragraph separators, line breaks a one-line title must not hide.
        const QChar::Category category = QChar::category(char32_t(c));
        if (category == QChar::Other_Control || category == QChar::Other_Format || category == QChar::Separator_Line
            || category == QChar::Separator_Paragraph || isBidiControl(char32_t(c)))
            return QStringLiteral("control, format or separator character U+%1").arg(QString::number(c, 16).toUpper().rightJustified(4, u'0'));
    }
    if (text.contains(u'<') || text.contains(u'>') || matches(text, R"(&(#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);)"))
        return QStringLiteral("markup (< > or an &entity;): plain text only");
    if (text.normalized(QString::NormalizationForm_C) != text)
        return QStringLiteral("not in Unicode NFC form");
    return {};
}

QString cleanPlainText(const QString &text, int limit, bool lineFeeds)
{
    QString out;
    out.reserve(text.size());
    bool space = false;
    for (const QChar c : text) {
        const char16_t u = c.unicode();
        if (u == '\n' && lineFeeds) {
            while (out.endsWith(QLatin1Char(' ')))
                out.chop(1);
            out += QLatin1Char('\n');
            space = false;
            continue;
        }
        if (c.isSpace()) {
            space = !out.isEmpty() && !out.endsWith(QLatin1Char('\n'));
            continue;
        }
        if (c.category() == QChar::Other_Control || c.category() == QChar::Other_Format)
            continue;
        if (space)
            out += QLatin1Char(' ');
        space = false;
        out += c;
    }
    out = out.trimmed();
    const QList<uint> cps = out.toUcs4();
    if (cps.size() > limit)
        out = QString::fromUcs4(reinterpret_cast<const char32_t *>(cps.constData()), limit - 1).trimmed() + QChar(0x2026);
    return out.normalized(QString::NormalizationForm_C);
}

bool isPackageName(const QString &name)
{
    return matches(name, R"(\A[a-z0-9@_+][a-z0-9@._+-]{0,127}\z)");
}

bool isAppId(const QString &id)
{
    return matches(id, R"(\A[A-Za-z0-9._-]{1,255}\z)");
}

bool isDesktopId(const QString &id)
{
    return matches(id, R"(\A[A-Za-z0-9._-]{1,250}\.desktop\z)");
}

bool isFlatpakId(const QString &id)
{
    return id.toUtf8().size() <= 255 && matches(id, R"(\A[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}\z)");
}

bool isHttpsUrl(const QString &url)
{
    if (url.toUtf8().size() > 2048 || !url.startsWith(QLatin1String("https://")))
        return false;
    for (const QChar c : url) {
        if (c.isSpace() || c.category() == QChar::Other_Control || c.category() == QChar::Other_Format)
            return false;
    }
    // The authority: no user information, a host name (any case, compared in lower case), an optional port.
    const QString rest = url.mid(8);
    const qsizetype end = rest.indexOf(QRegularExpression(QStringLiteral("[/?#]")));
    const QString authority = end < 0 ? rest : rest.left(end);
    if (authority.contains(u'@'))
        return false;
    const qsizetype colon = authority.lastIndexOf(u':');
    if (colon >= 0) {
        const QString port = authority.mid(colon + 1);
        if (!port.isEmpty() && (!matches(port, R"(\A[0-9]{1,5}\z)") || port.toInt() > 65535))
            return false;
    }
    const QString host = (colon < 0 ? authority : authority.left(colon)).toLower();
    return matches(host, R"(\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z)");
}

bool isWebAppName(const QString &name)
{
    const qsizetype length = name.toUcs4().size();
    return length >= 1 && length <= 64 && !name.startsWith(u'.') && !name.contains(u'/')
        && plainTextProblem(name, 64, false).isEmpty();
}

CatalogParse parseCatalog(const QByteArray &json, const QString &expectedChannel)
{
    CatalogParse result;
    auto refuse = [&](const QString &why) {
        result.refusal = why;
        return result;
    };
    if (json.size() > kCatalogMaxBytes)
        return refuse(QStringLiteral("larger than 1 MiB"));
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return refuse(QStringLiteral("not a JSON object"));
    const QJsonObject top = doc.object();
    if (top.value(QStringLiteral("version")).toInteger(-1) != 1 || !top.value(QStringLiteral("version")).isDouble())
        return refuse(QStringLiteral("version is not 1"));
    Catalog catalog;
    catalog.channel = top.value(QStringLiteral("channel")).toString();
    if (catalog.channel != QLatin1String("stable") && catalog.channel != QLatin1String("beta"))
        return refuse(QStringLiteral("unknown channel"));
    if (catalog.channel != expectedChannel)
        return refuse(QStringLiteral("for the channel %1, fetched for %2").arg(catalog.channel, expectedChannel));
    const QJsonValue serial = top.value(QStringLiteral("serial"));
    const double s = serial.toDouble(-1);
    if (!serial.isDouble() || s != std::floor(s) || s <= 0 || s >= 9007199254740992.0)
        return refuse(QStringLiteral("serial is not a positive integer"));
    catalog.serial = qint64(s);
    catalog.generated = top.value(QStringLiteral("generated")).toString();
    if (!matches(catalog.generated, R"(\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z)"))
        return refuse(QStringLiteral("generated is not a UTC time"));
    const QJsonValue sections = top.value(QStringLiteral("sections")), categories = top.value(QStringLiteral("categories")),
                     apps = top.value(QStringLiteral("apps"));
    if (!sections.isArray() || sections.toArray().isEmpty() || sections.toArray().size() > 8 || !categories.isArray()
        || categories.toArray().size() > 32 || !apps.isArray() || apps.toArray().size() > 2000)
        return refuse(QStringLiteral("sections, categories or apps missing or over their bounds"));

    QSet<QString> categoryIds;
    for (const QJsonValue &v : categories.toArray()) {
        const QJsonObject o = v.toObject();
        CatalogCategory c;
        c.id = o.value(QStringLiteral("id")).toString();
        c.symbol = o.value(QStringLiteral("symbol")).toString();
        QString why;
        const bool ok = v.isObject() && isSectionId(c.id) && !categoryIds.contains(c.id) && isSymbol(c.symbol)
            && requiredText(o, "title", kLenSectionTitle, false, &c.title, &why)
            && stringList(o.value(QStringLiteral("freedesktop")), 1, 16,
                          [](const QString &n) { return matches(n, R"(\A[A-Za-z0-9-]{1,64}\z)"); }, &c.freedesktop);
        if (!ok) {
            result.dropped.append(QStringLiteral("category %1: %2").arg(c.id, why.isEmpty() ? QStringLiteral("id, symbol or freedesktop") : why));
            continue;
        }
        categoryIds.insert(c.id);
        catalog.categories.append(c);
    }

    QSet<QString> appIds, seen;
    for (const QJsonValue &v : apps.toArray()) {
        QString why;
        const auto app = parseApp(v, categoryIds, &why);
        const QString id = v.toObject().value(QStringLiteral("id")).toString();
        if (seen.contains(id) && !id.isEmpty()) {
            // Both copies go: which one CI meant is unknown.
            appIds.remove(id);
            catalog.apps.removeIf([&](const CatalogApp &a) { return a.id == id; });
            result.dropped.append(QStringLiteral("app %1: its id appears twice").arg(id));
            continue;
        }
        seen.insert(id);
        if (!app) {
            result.dropped.append(QStringLiteral("app %1: %2").arg(id, why));
            continue;
        }
        appIds.insert(app->id);
        catalog.apps.append(*app);
    }

    QSet<QString> sectionIds;
    bool first = true;
    for (const QJsonValue &v : sections.toArray()) {
        const QJsonObject o = v.toObject();
        CatalogSection section;
        section.id = o.value(QStringLiteral("id")).toString();
        section.symbol = o.value(QStringLiteral("symbol")).toString();
        QString why;
        const bool wasFirst = first;
        first = false;
        if (wasFirst && section.id != QLatin1String("discover"))
            return refuse(QStringLiteral("the first section is not discover"));
        if (!v.isObject() || !isSectionId(section.id) || sectionIds.contains(section.id) || !isSymbol(section.symbol)
            || !requiredText(o, "title", kLenSectionTitle, false, &section.title, &why)
            || !o.value(QStringLiteral("blocks")).isArray() || o.value(QStringLiteral("blocks")).toArray().size() > 12) {
            result.dropped.append(QStringLiteral("section %1: %2").arg(section.id, why.isEmpty() ? QStringLiteral("id, symbol or blocks") : why));
            continue;
        }
        sectionIds.insert(section.id);
        int index = 0;
        for (const QJsonValue &bv : o.value(QStringLiteral("blocks")).toArray()) {
            const QString where = QStringLiteral("section %1 block %2").arg(section.id).arg(index++);
            const QJsonObject b = bv.toObject();
            const QString kind = b.value(QStringLiteral("kind")).toString();
            CatalogBlock block;
            if (kind == QLatin1String("row")) {
                block.kind = CatalogBlock::Kind::Row;
                QStringList ids;
                QString textWhy;
                if (!requiredText(b, "title", kLenTitle, false, &block.title, &textWhy)
                    || !stringList(b.value(QStringLiteral("apps")), 1, 24, [](const QString &) { return true; }, &ids)) {
                    result.dropped.append(where + QStringLiteral(": title or apps"));
                    continue;
                }
                for (const QString &id : ids) {
                    if (appIds.contains(id) && !block.apps.contains(id))
                        block.apps.append(id);
                }
                if (block.apps.isEmpty()) {
                    result.dropped.append(where + QStringLiteral(": none of its apps is left"));
                    continue;
                }
            } else if (kind == QLatin1String("hero") || kind == QLatin1String("cards")) {
                block.kind = kind == QLatin1String("hero") ? CatalogBlock::Kind::Hero : CatalogBlock::Kind::Cards;
                const QJsonArray items = b.value(QStringLiteral("items")).toArray();
                const int most = block.kind == CatalogBlock::Kind::Hero ? 8 : 12;
                if (!b.value(QStringLiteral("items")).isArray() || items.isEmpty() || items.size() > most) {
                    result.dropped.append(where + QStringLiteral(": items"));
                    continue;
                }
                for (const QJsonValue &iv : items) {
                    const QJsonObject io = iv.toObject();
                    CatalogItem item;
                    item.app = io.value(QStringLiteral("app")).toString();
                    QString itemWhy;
                    if (!appIds.contains(item.app) || !requiredText(io, "title", kLenTitle, false, &item.title, &itemWhy)
                        || !optionalText(io, "eyebrow", kLenEyebrow, false, &item.eyebrow, &itemWhy)
                        || !optionalText(io, "text", kLenText, true, &item.text, &itemWhy)) {
                        result.dropped.append(QStringLiteral("%1 item %2: %3").arg(where, item.app, itemWhy.isEmpty() ? QStringLiteral("app") : itemWhy));
                        continue;
                    }
                    block.items.append(item);
                }
                if (block.items.isEmpty()) {
                    result.dropped.append(where + QStringLiteral(": none of its items is left"));
                    continue;
                }
            } else {
                result.dropped.append(where + QStringLiteral(": unknown kind"));
                continue;
            }
            section.blocks.append(block);
        }
        if (section.blocks.isEmpty()) {
            result.dropped.append(QStringLiteral("section %1: no block is left").arg(section.id));
            continue;
        }
        catalog.sections.append(section);
    }
    result.catalog = catalog;
    return result;
}

} // namespace grassfield::store
