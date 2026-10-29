#include "aur.h"

#include "catalog.h"
#include "fetch.h"
#include "runmode.h"

#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QTimeZone>

#include <algorithm>

namespace grassfield::store {

namespace {

constexpr qint64 kAnswerMax = 512 * 1024; // ADR-0037 c: an AUR answer
constexpr qint64 kCacheMax = 4 * 1024 * 1024;
constexpr qint64 kCacheSeconds = 3600;
constexpr int kInfoNamesMax = 150;
constexpr int kInfoChunk = 50;
constexpr int kSearchResults = 50;
constexpr int kDependenciesMax = 300;

bool matches(const QString &text, const char *pattern)
{
    const QRegularExpression re(QString::fromLatin1(pattern));
    return re.match(text).hasMatch();
}

bool isVersion(const QString &v)
{
    return matches(v, R"(\A[A-Za-z0-9._+:~-]{1,64}\z)");
}

// A time the AUR gives (Unix seconds): between the AUR's first year and a day from now, else invalid.
QDateTime aurTime(const QJsonValue &v)
{
    if (!v.isDouble())
        return {};
    const double s = v.toDouble();
    const double now = double(QDateTime::currentSecsSinceEpoch());
    if (s < 1104537600.0 || s > now + 86400.0) // 2005-01-01
        return {};
    return QDateTime::fromSecsSinceEpoch(qint64(s), QTimeZone::UTC);
}

QStringList plainList(const QJsonValue &v, int count, int limit)
{
    QStringList out;
    for (const QJsonValue &item : v.toArray()) {
        if (out.size() >= count)
            break;
        const QString text = cleanPlainText(item.toString(), limit, false);
        if (!text.isEmpty())
            out.append(text);
    }
    return out;
}

// The dependencies the Store reads; `unread` when one is not.
QStringList dependencies(const QJsonValue &v, bool *unread, bool optional)
{
    QStringList out;
    const QJsonArray array = v.toArray();
    if (!v.isUndefined() && !v.isNull() && !v.isArray())
        *unread = true;
    for (const QJsonValue &item : array) {
        if (out.size() >= kDependenciesMax) {
            *unread = true;
            break;
        }
        const QString text = item.toString();
        if (text.size() > 200 || dependencyName(text).isEmpty()) {
            if (!optional)
                *unread = true;
            continue;
        }
        out.append(optional ? cleanPlainText(text, 200, false) : text);
    }
    return out;
}

std::optional<AurPackage> readPackage(const QJsonObject &o)
{
    AurPackage p;
    p.name = o.value(QStringLiteral("Name")).toString();
    p.version = o.value(QStringLiteral("Version")).toString();
    p.base = o.value(QStringLiteral("PackageBase")).toString();
    if (!isPackageName(p.name) || !isVersion(p.version) || !isPackageName(p.base))
        return std::nullopt;
    p.description = cleanPlainText(o.value(QStringLiteral("Description")).toString(), 400, false);
    const QJsonValue maintainer = o.value(QStringLiteral("Maintainer"));
    p.orphaned = maintainer.isNull();
    const QString m = maintainer.toString();
    if (matches(m, R"(\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z)"))
        p.maintainer = m;
    p.votes = std::clamp(o.value(QStringLiteral("NumVotes")).toInt(0), 0, 10000000);
    p.popularity = std::clamp(o.value(QStringLiteral("Popularity")).toDouble(0), 0.0, 1000000.0);
    p.outOfDate = aurTime(o.value(QStringLiteral("OutOfDate")));
    p.lastModified = aurTime(o.value(QStringLiteral("LastModified")));
    p.firstSubmitted = aurTime(o.value(QStringLiteral("FirstSubmitted")));
    p.licenses = plainList(o.value(QStringLiteral("License")), 8, 64);
    const QString url = o.value(QStringLiteral("URL")).toString();
    if (isHttpsUrl(url))
        p.url = url;
    p.keywords = plainList(o.value(QStringLiteral("Keywords")), 20, 64);
    p.depends = dependencies(o.value(QStringLiteral("Depends")), &p.dependenciesUnread, false);
    p.makeDepends = dependencies(o.value(QStringLiteral("MakeDepends")), &p.dependenciesUnread, false);
    p.checkDepends = dependencies(o.value(QStringLiteral("CheckDepends")), &p.dependenciesUnread, false);
    bool unusedOptional = false;
    p.optDepends = dependencies(o.value(QStringLiteral("OptDepends")), &unusedOptional, true);
    return p;
}

// --- the cache: one file per answer, fresh for an hour, 4 MiB in all ---------------------------------------------------

QString cachePath(const AurConfig &c, const QString &kind, const QString &key)
{
    return c.cacheDir + QLatin1Char('/') + kind + QLatin1Char('/') + key;
}

std::optional<QByteArray> cacheGet(const AurConfig &c, const QString &kind, const QString &key)
{
    if (c.cacheDir.isEmpty())
        return std::nullopt;
    const QFileInfo info(cachePath(c, kind, key));
    if (!info.isFile() || info.size() > kAnswerMax
        || info.lastModified().secsTo(QDateTime::currentDateTime()) > kCacheSeconds || info.lastModified() > QDateTime::currentDateTime().addSecs(60))
        return std::nullopt;
    QFile f(info.filePath());
    if (!f.open(QIODevice::ReadOnly))
        return std::nullopt;
    return f.read(kAnswerMax);
}

void cachePrune(const AurConfig &c)
{
    struct Entry {
        QString path;
        qint64 size;
        QDateTime at;
    };
    QList<Entry> entries;
    qint64 total = 0;
    QDirIterator it(c.cacheDir, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QFileInfo info(it.next());
        entries.append({info.filePath(), info.size(), info.lastModified()});
        total += info.size();
    }
    if (total <= kCacheMax)
        return;
    std::sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) { return a.at < b.at; });
    for (const Entry &e : entries) {
        if (total <= kCacheMax)
            break;
        if (QFile::remove(e.path))
            total -= e.size;
    }
}

void cachePut(const AurConfig &c, const QString &kind, const QString &key, const QByteArray &bytes)
{
    if (c.cacheDir.isEmpty() || bytes.size() > kAnswerMax)
        return;
    const QString path = cachePath(c, kind, key);
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return;
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size() || !f.commit())
        return;
    cachePrune(c);
}

FetchResult ask(const AurConfig &c, const QUrl &url)
{
    return fetch(url, FetchLimits{kAnswerMax, c.timeoutMs}, {}, c.devPlumbing);
}

// The dev plumbing's file for an answer (its folder's info.json, search.json, pkgbuild/<base>).
QUrl devFile(const AurConfig &c, const QString &relative)
{
    return QUrl::fromLocalFile(c.base.toLocalFile() + QLatin1Char('/') + relative);
}

QString hexOf(const QString &text)
{
    return QString::fromLatin1(QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha256).toHex());
}

} // namespace

AurAnswer parseAurAnswer(const QByteArray &json, const QString &expectedType)
{
    AurAnswer out;
    if (json.size() > kAnswerMax) {
        out.error = QStringLiteral("malformed");
        return out;
    }
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    const QJsonObject root = doc.object();
    if (error.error != QJsonParseError::NoError || !doc.isObject() || root.value(QStringLiteral("version")).toInt(0) != 5) {
        out.error = QStringLiteral("malformed");
        return out;
    }
    const QString type = root.value(QStringLiteral("type")).toString();
    if (type == QLatin1String("error")) {
        const QString why = cleanPlainText(root.value(QStringLiteral("error")).toString(), 200, false);
        out.error = why.isEmpty() ? QStringLiteral("malformed") : why;
        return out;
    }
    if (type != expectedType || !root.value(QStringLiteral("results")).isArray()) {
        out.error = QStringLiteral("malformed");
        return out;
    }
    QSet<QString> seen;
    for (const QJsonValue &v : root.value(QStringLiteral("results")).toArray()) {
        if (out.packages.size() >= 5000)
            break;
        const std::optional<AurPackage> p = readPackage(v.toObject());
        if (p && !seen.contains(p->name)) {
            seen.insert(p->name);
            out.packages.append(*p);
        }
    }
    out.ok = true;
    return out;
}

QString dependencyName(const QString &dependency)
{
    QString text = dependency;
    const qsizetype colon = text.indexOf(QLatin1Char(':'));
    // An optional dependency's reason ("name: why"); an epoch in a version ("name>=1:2") keeps its colon.
    if (colon > 0 && colon + 1 < text.size() && text.at(colon + 1) == QLatin1Char(' '))
        text = text.left(colon);
    static const QRegularExpression re(QStringLiteral(R"(\A([a-z0-9@_+][a-z0-9@._+-]{0,127})(?:(<=|>=|=|<|>)[A-Za-z0-9._+:~-]{1,64})?\z)"));
    const QRegularExpressionMatch m = re.match(text);
    return m.hasMatch() ? m.captured(1) : QString();
}

bool isAurSearchTerm(const QString &term)
{
    const QList<uint> points = term.toUcs4();
    if (points.size() < 2 || points.size() > 64 || term.contains(QLatin1Char('/')) || term.trimmed().size() < 2)
        return false;
    for (const uint u : points) {
        const auto cat = QChar::category(char32_t(u));
        if (cat == QChar::Other_Control || cat == QChar::Other_Format)
            return false;
    }
    return true;
}

AurConfig aurConfig(const QString &storeCacheDir)
{
    AurConfig c;
    const QString dev = apps::runmode::devValue("STORE_AUR_URL");
    if (!dev.isEmpty()) {
        c.base = QUrl(dev);
        c.devPlumbing = c.base.isLocalFile();
    } else {
        c.base = QUrl(QStringLiteral("https://aur.archlinux.org"));
    }
    c.cacheDir = storeCacheDir.isEmpty() ? QString() : storeCacheDir + QStringLiteral("/aur");
    return c;
}

QUrl aurInfoUrl(const QUrl &base, const QStringList &names)
{
    // Each name percent-encoded as the search's term: a '+' left as it is (libc++) reads as a space in a query.
    QStringList args;
    for (const QString &n : names)
        args.append(QStringLiteral("arg[]=") + QString::fromLatin1(QUrl::toPercentEncoding(n)));
    return QUrl(base.toString(QUrl::StripTrailingSlash) + QStringLiteral("/rpc/v5/info?") + args.join(QLatin1Char('&')));
}

QUrl aurSearchUrl(const QUrl &base, const QString &term)
{
    return QUrl(base.toString(QUrl::StripTrailingSlash) + QStringLiteral("/rpc/v5/search/")
                + QString::fromLatin1(QUrl::toPercentEncoding(term)) + QStringLiteral("?by=name"), QUrl::StrictMode);
}

QUrl aurPkgbuildUrl(const QUrl &base, const QString &packageBase)
{
    return QUrl(base.toString(QUrl::StripTrailingSlash) + QStringLiteral("/cgit/aur.git/plain/PKGBUILD?h=")
                + QString::fromLatin1(QUrl::toPercentEncoding(packageBase)), QUrl::StrictMode);
}

AurAnswer aurInfo(const AurConfig &config, const QStringList &names)
{
    AurAnswer out;
    out.ok = true;
    QStringList asked;
    for (const QString &n : names) {
        if (isPackageName(n) && !asked.contains(n) && asked.size() < kInfoNamesMax)
            asked.append(n);
    }
    QHash<QString, AurPackage> found;
    QStringList missing;
    for (const QString &n : asked) {
        const std::optional<QByteArray> cached = cacheGet(config, QStringLiteral("info"), n + QStringLiteral(".json"));
        const AurAnswer one = cached ? parseAurAnswer("{\"version\":5,\"type\":\"multiinfo\",\"results\":[" + *cached + "]}", QStringLiteral("multiinfo"))
                                     : AurAnswer();
        if (one.ok && one.packages.size() == 1 && one.packages.constFirst().name == n)
            found.insert(n, one.packages.constFirst());
        else
            missing.append(n);
    }
    for (qsizetype i = 0; i < missing.size(); i += kInfoChunk) {
        const QStringList chunk = missing.mid(i, kInfoChunk);
        const FetchResult r = ask(config, config.devPlumbing ? devFile(config, QStringLiteral("info.json")) : aurInfoUrl(config.base, chunk));
        if (r.status != FetchResult::Status::Ok) {
            out.ok = false;
            out.error = QStringLiteral("unavailable");
            continue;
        }
        const AurAnswer answer = parseAurAnswer(r.body, QStringLiteral("multiinfo"));
        if (!answer.ok) {
            out.ok = false;
            out.error = answer.error;
            continue;
        }
        // Each package asked is cached on its own, as the AUR wrote it.
        const QJsonArray results = QJsonDocument::fromJson(r.body).object().value(QStringLiteral("results")).toArray();
        for (const QJsonValue &v : results) {
            const QString name = v.toObject().value(QStringLiteral("Name")).toString();
            if (chunk.contains(name))
                cachePut(config, QStringLiteral("info"), name + QStringLiteral(".json"), QJsonDocument(v.toObject()).toJson(QJsonDocument::Compact));
        }
        for (const AurPackage &p : answer.packages) {
            if (chunk.contains(p.name))
                found.insert(p.name, p);
        }
    }
    for (const QString &n : asked) {
        if (found.contains(n))
            out.packages.append(found.value(n));
    }
    return out;
}

AurAnswer aurSearch(const AurConfig &config, const QString &term)
{
    if (!isAurSearchTerm(term))
        return AurAnswer{false, {}, QStringLiteral("malformed")};
    const QString key = hexOf(term.trimmed().toLower()) + QStringLiteral(".json");
    QByteArray body;
    bool fromCache = false;
    if (const std::optional<QByteArray> cached = cacheGet(config, QStringLiteral("search"), key)) {
        body = *cached;
        fromCache = true;
    } else {
        const FetchResult r = ask(config, config.devPlumbing ? devFile(config, QStringLiteral("search.json"))
                                                             : aurSearchUrl(config.base, term.trimmed()));
        if (r.status != FetchResult::Status::Ok)
            return AurAnswer{false, {}, QStringLiteral("unavailable")};
        body = r.body;
    }
    AurAnswer answer = parseAurAnswer(body, QStringLiteral("search"));
    if (!answer.ok)
        return answer;
    if (!fromCache)
        cachePut(config, QStringLiteral("search"), key, body);
    if (config.devPlumbing) {
        // The fixture's answer holds every package: only those the AUR would find by name.
        const QString t = term.trimmed().toLower();
        answer.packages.removeIf([&t](const AurPackage &p) { return !p.name.contains(t); });
    }
    std::stable_sort(answer.packages.begin(), answer.packages.end(), [](const AurPackage &a, const AurPackage &b) {
        return a.votes != b.votes ? a.votes > b.votes : a.name < b.name;
    });
    if (answer.packages.size() > kSearchResults)
        answer.packages.resize(kSearchResults);
    return answer;
}

std::optional<QString> aurPkgbuild(const AurConfig &config, const QString &packageBase)
{
    if (!isPackageName(packageBase))
        return std::nullopt;
    QByteArray body;
    if (const std::optional<QByteArray> cached = cacheGet(config, QStringLiteral("pkgbuild"), packageBase)) {
        body = *cached;
    } else {
        const FetchResult r = ask(config, config.devPlumbing ? devFile(config, QStringLiteral("pkgbuild/") + packageBase)
                                                             : aurPkgbuildUrl(config.base, packageBase));
        if (r.status != FetchResult::Status::Ok)
            return std::nullopt;
        body = r.body;
        cachePut(config, QStringLiteral("pkgbuild"), packageBase, body);
    }
    // Plain text: line feeds and tabs kept, every other control and format character removed (by code point).
    QString text;
    for (const uint u : QString::fromUtf8(body).toUcs4()) {
        const char32_t c = char32_t(u);
        const auto cat = QChar::category(c);
        if (c == U'\n' || c == U'\t' || (cat != QChar::Other_Control && cat != QChar::Other_Format && c != 0xFFFD))
            text.append(QString::fromUcs4(&c, 1));
    }
    return text;
}

} // namespace grassfield::store
