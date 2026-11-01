#include "searchlogic.h"

#include <algorithm>

#include <QJsonArray>
#include <QUrlQuery>

namespace SearchLogic
{
namespace
{
const QList<QPair<Attribute, const char *>> kAttributes = {
    {Attribute::Kind, "kind"},       {Attribute::Opened, "opened"},     {Attribute::Modified, "modified"}, {Attribute::Created, "created"},
    {Attribute::Name, "name"},       {Attribute::Contents, "contents"}, {Attribute::Size, "size"},         {Attribute::Tags, "tags"},
};

const QList<QPair<Op, const char *>> kOps = {
    {Op::Is, "is"},
    {Op::IsNot, "is-not"},
    {Op::Contains, "contains"},
    {Op::BeginsWith, "begins-with"},
    {Op::EndsWith, "ends-with"},
    {Op::WithinLast, "within-last"},
    {Op::Exactly, "exactly"},
    {Op::Before, "before"},
    {Op::After, "after"},
    {Op::Today, "today"},
    {Op::Yesterday, "yesterday"},
    {Op::ThisWeek, "this-week"},
    {Op::ThisMonth, "this-month"},
    {Op::ThisYear, "this-year"},
    {Op::Greater, "greater"},
    {Op::Less, "less"},
};

const QList<QPair<FileLogic::KindCategory, const char *>> kKinds = {
    {FileLogic::KindCategory::Application, "application"},
    {FileLogic::KindCategory::Archive, "archive"},
    {FileLogic::KindCategory::Document, "document"},
    {FileLogic::KindCategory::Folder, "folder"},
    {FileLogic::KindCategory::Image, "image"},
    {FileLogic::KindCategory::Movie, "movie"},
    {FileLogic::KindCategory::Music, "music"},
    {FileLogic::KindCategory::Pdf, "pdf"},
    {FileLogic::KindCategory::Presentation, "presentation"},
    {FileLogic::KindCategory::Spreadsheet, "spreadsheet"},
    {FileLogic::KindCategory::Other, "other"},
};

bool needsValue(Op op)
{
    switch (op) {
    case Op::Today:
    case Op::Yesterday:
    case Op::ThisWeek:
    case Op::ThisMonth:
    case Op::ThisYear:
        return false;
    default:
        return true;
    }
}

// A positive whole number from a row's field ("12"), else -1.
qint64 positiveNumber(const QString &value)
{
    bool ok = false;
    const qint64 n = value.trimmed().toLongLong(&ok);
    return ok && n >= 0 ? n : -1;
}

QDate isoDate(const QString &value)
{
    return QDate::fromString(value.trimmed(), Qt::ISODate);
}

bool dateHolds(const Criterion &c, const QDateTime &when, const QDateTime &now)
{
    if (!when.isValid())
        return false;
    const QDate day = when.toLocalTime().date();
    const QDate today = now.toLocalTime().date();
    switch (c.op) {
    case Op::Today:
        return day == today;
    case Op::Yesterday:
        return day == today.addDays(-1);
    case Op::ThisWeek:
        // The locale's week (Monday-first in French, Sunday-first in US English), as the Finder's "this week".
        return day >= today.addDays(-((today.dayOfWeek() - int(QLocale().firstDayOfWeek()) + 7) % 7)) && day <= today;
    case Op::ThisMonth:
        return day.year() == today.year() && day.month() == today.month();
    case Op::ThisYear:
        return day.year() == today.year();
    case Op::Exactly:
        return day == isoDate(c.value);
    case Op::Before:
        return day < isoDate(c.value);
    case Op::After:
        return day > isoDate(c.value);
    case Op::WithinLast: {
        const qint64 n = positiveNumber(c.value);
        if (n < 0)
            return true;
        QDateTime from = now;
        if (c.unit == QLatin1String("weeks"))
            from = now.addDays(-7 * n);
        else if (c.unit == QLatin1String("months"))
            from = now.addMonths(-int(n));
        else if (c.unit == QLatin1String("years"))
            from = now.addYears(-int(n));
        else
            from = now.addDays(-n);
        return when >= from;
    }
    default:
        return true;
    }
}

qint64 sizeInBytes(const Criterion &c)
{
    const qint64 n = positiveNumber(c.value);
    if (n < 0)
        return -1;
    if (c.unit == QLatin1String("GB"))
        return n * 1000 * 1000 * 1000;
    if (c.unit == QLatin1String("MB"))
        return n * 1000 * 1000;
    return n * 1000;
}

bool tagMatches(const QStringList &tags, const QString &wanted)
{
    for (const QString &tag : tags) {
        if (tag.compare(wanted, Qt::CaseInsensitive) == 0)
            return true;
    }
    return false;
}
} // namespace

QString scheme()
{
    return QStringLiteral("grassfield-search");
}

bool isSearchUrl(const QUrl &url)
{
    return url.scheme() == scheme();
}

QString attributeKey(Attribute attribute)
{
    for (const auto &[a, key] : kAttributes) {
        if (a == attribute)
            return QString::fromLatin1(key);
    }
    return QString();
}

std::optional<Attribute> attributeFromKey(const QString &key)
{
    for (const auto &[a, k] : kAttributes) {
        if (key == QLatin1String(k))
            return a;
    }
    return std::nullopt;
}

QString opKey(Op op)
{
    for (const auto &[o, key] : kOps) {
        if (o == op)
            return QString::fromLatin1(key);
    }
    return QString();
}

std::optional<Op> opFromKey(const QString &key)
{
    for (const auto &[o, k] : kOps) {
        if (key == QLatin1String(k))
            return o;
    }
    return std::nullopt;
}

QString kindKey(FileLogic::KindCategory category)
{
    for (const auto &[c, key] : kKinds) {
        if (c == category)
            return QString::fromLatin1(key);
    }
    return QString();
}

std::optional<FileLogic::KindCategory> kindFromKey(const QString &key)
{
    for (const auto &[c, k] : kKinds) {
        if (key == QLatin1String(k))
            return c;
    }
    return std::nullopt;
}

QList<Op> operatorsFor(Attribute attribute)
{
    switch (attribute) {
    case Attribute::Kind:
        return {Op::Is, Op::IsNot};
    case Attribute::Opened:
    case Attribute::Modified:
    case Attribute::Created:
        return {Op::WithinLast, Op::Exactly, Op::Before, Op::After, Op::Today, Op::Yesterday, Op::ThisWeek, Op::ThisMonth, Op::ThisYear};
    case Attribute::Name:
        return {Op::Contains, Op::BeginsWith, Op::EndsWith, Op::Is};
    case Attribute::Contents:
        return {Op::Contains};
    case Attribute::Size:
        return {Op::Greater, Op::Less};
    case Attribute::Tags:
        return {Op::Is};
    }
    return {};
}

bool takesOp(Attribute attribute, Op op)
{
    return operatorsFor(attribute).contains(op);
}

bool isComplete(const Criterion &c)
{
    if (!takesOp(c.attribute, c.op))
        return false;
    if (!needsValue(c.op))
        return true;
    switch (c.attribute) {
    case Attribute::Kind:
        return c.value == QLatin1String("any") || kindFromKey(c.value).has_value();
    case Attribute::Opened:
    case Attribute::Modified:
    case Attribute::Created:
        return c.op == Op::WithinLast ? positiveNumber(c.value) > 0 : isoDate(c.value).isValid();
    case Attribute::Size:
        return positiveNumber(c.value) >= 0 && !c.value.trimmed().isEmpty();
    case Attribute::Name:
    case Attribute::Contents:
    case Attribute::Tags:
        return !c.value.trimmed().isEmpty();
    }
    return false;
}

QUrl toUrl(const Query &query)
{
    QUrl url;
    url.setScheme(scheme());
    url.setPath(QStringLiteral("/"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("q"), QString::fromUtf8(QUrl::toPercentEncoding(query.text)));
    if (!query.inComputer())
        q.addQueryItem(QStringLiteral("in"), QString::fromUtf8(QUrl::toPercentEncoding(query.folder.toString(QUrl::FullyEncoded))));
    for (const Criterion &c : query.criteria) {
        const QString row = attributeKey(c.attribute) + QLatin1Char(':') + opKey(c.op) + QLatin1Char(':') + c.unit + QLatin1Char(':') + c.value;
        q.addQueryItem(QStringLiteral("c"), QString::fromUtf8(QUrl::toPercentEncoding(row)));
    }
    url.setQuery(q);
    return url;
}

std::optional<Query> fromUrl(const QUrl &url)
{
    if (!isSearchUrl(url))
        return std::nullopt;
    const QUrlQuery q(url);
    Query query;
    query.text = QUrl::fromPercentEncoding(q.queryItemValue(QStringLiteral("q"), QUrl::FullyEncoded).toUtf8());
    const QString in = QUrl::fromPercentEncoding(q.queryItemValue(QStringLiteral("in"), QUrl::FullyEncoded).toUtf8());
    if (!in.isEmpty()) {
        const QUrl folder(in, QUrl::StrictMode);
        if (!folder.isValid() || !folder.isLocalFile() || !folder.toLocalFile().startsWith(QLatin1Char('/')))
            return std::nullopt;
        query.folder = folder.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    }
    for (const QString &encoded : q.allQueryItemValues(QStringLiteral("c"), QUrl::FullyEncoded)) {
        const QString row = QUrl::fromPercentEncoding(encoded.toUtf8());
        const QStringList parts = row.split(QLatin1Char(':'));
        if (parts.size() < 4)
            return std::nullopt;
        const auto attribute = attributeFromKey(parts.at(0));
        const auto op = opFromKey(parts.at(1));
        if (!attribute || !op || !takesOp(*attribute, *op))
            return std::nullopt;
        // The value is the rest: it may hold ':' itself.
        query.criteria.append({*attribute, *op, parts.mid(3).join(QLatin1Char(':')), parts.at(2)});
    }
    return query;
}

bool textMatchesName(const QString &text, const QString &name)
{
    const QStringList words = text.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString &word : words) {
        if (!FileLogic::nameMatchesFilter(name, word))
            return false;
    }
    return true;
}

bool matchesCriteria(const Query &query, const Facts &facts, const QDateTime &now)
{
    for (const Criterion &c : query.criteria) {
        if (!isComplete(c))
            continue;
        switch (c.attribute) {
        case Attribute::Kind: {
            if (c.value == QLatin1String("any"))
                break;
            const bool same = kindFromKey(c.value) == facts.kind;
            if (same != (c.op == Op::Is))
                return false;
            break;
        }
        case Attribute::Opened:
            if (!dateHolds(c, facts.opened, now))
                return false;
            break;
        case Attribute::Modified:
            if (!dateHolds(c, facts.modified, now))
                return false;
            break;
        case Attribute::Created:
            if (!dateHolds(c, facts.created, now))
                return false;
            break;
        case Attribute::Name: {
            const QString name = FileLogic::foldForMatch(facts.name);
            const QString value = FileLogic::foldForMatch(c.value.trimmed());
            const bool holds = c.op == Op::Is           ? name == value
                               : c.op == Op::BeginsWith ? name.startsWith(value)
                               : c.op == Op::EndsWith   ? name.endsWith(value)
                                                        : name.contains(value);
            if (!holds)
                return false;
            break;
        }
        case Attribute::Contents:
            break;
        case Attribute::Size: {
            // A folder has no size here (the Finder's search matches files on size).
            if (facts.isDir || facts.size < 0)
                return false;
            const qint64 bytes = sizeInBytes(c);
            if (c.op == Op::Greater ? facts.size <= bytes : facts.size >= bytes)
                return false;
            break;
        }
        case Attribute::Tags:
            if (!tagMatches(facts.tags, c.value.trimmed()))
                return false;
            break;
        }
    }
    return true;
}

QString contentsText(const Query &query)
{
    QStringList parts;
    for (const Criterion &c : query.criteria) {
        if (c.attribute == Attribute::Contents && isComplete(c))
            parts.append(c.value.trimmed());
    }
    return parts.join(QLatin1Char(' '));
}

QString nameTerm(const Query &query)
{
    if (!query.text.trimmed().isEmpty())
        return query.text.trimmed();
    for (const Criterion &c : query.criteria) {
        if (c.attribute == Attribute::Name && isComplete(c))
            return c.value.trimmed();
    }
    return QString();
}

bool needsFacts(const Query &query)
{
    for (const Criterion &c : query.criteria) {
        if (isComplete(c) && c.attribute != Attribute::Name && c.attribute != Attribute::Contents)
            return true;
    }
    return false;
}

bool hasTerms(const Query &query)
{
    if (!query.text.trimmed().isEmpty())
        return true;
    return std::any_of(query.criteria.cbegin(), query.criteria.cend(), [](const Criterion &c) { return isComplete(c); });
}

QJsonObject toJson(const Saved &saved)
{
    QJsonArray filters;
    for (const Criterion &c : saved.query.criteria) {
        filters.append(QJsonObject{{QStringLiteral("attribute"), attributeKey(c.attribute)},
                                   {QStringLiteral("op"), opKey(c.op)},
                                   {QStringLiteral("value"), c.value},
                                   {QStringLiteral("unit"), c.unit}});
    }
    return QJsonObject{{QStringLiteral("version"), kSavedVersion},
                       {QStringLiteral("name"), saved.name},
                       {QStringLiteral("scope"), saved.query.inComputer() ? QStringLiteral("computer") : saved.query.folder.toString(QUrl::FullyEncoded)},
                       {QStringLiteral("query"), saved.query.text},
                       {QStringLiteral("filters"), filters},
                       {QStringLiteral("sidebar"), saved.sidebar}};
}

std::optional<Saved> fromJson(const QJsonObject &object)
{
    const QJsonValue version = object.value(QStringLiteral("version"));
    if (!version.isDouble() || version.toInt() < 1 || version.toInt() > kSavedVersion)
        return std::nullopt;
    Saved saved;
    saved.name = object.value(QStringLiteral("name")).toString().trimmed();
    if (saved.name.isEmpty())
        return std::nullopt;
    const QString scope = object.value(QStringLiteral("scope")).toString();
    if (scope != QLatin1String("computer")) {
        const QUrl folder(scope, QUrl::StrictMode);
        if (!folder.isValid() || !folder.isLocalFile() || !folder.toLocalFile().startsWith(QLatin1Char('/')))
            return std::nullopt;
        saved.query.folder = folder.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    }
    saved.query.text = object.value(QStringLiteral("query")).toString();
    const QJsonValue filters = object.value(QStringLiteral("filters"));
    if (!filters.isUndefined() && !filters.isArray())
        return std::nullopt;
    for (const QJsonValue &v : filters.toArray()) {
        const QJsonObject row = v.toObject();
        const auto attribute = attributeFromKey(row.value(QStringLiteral("attribute")).toString());
        const auto op = opFromKey(row.value(QStringLiteral("op")).toString());
        if (!attribute || !op || !takesOp(*attribute, *op))
            return std::nullopt;
        saved.query.criteria.append({*attribute, *op, row.value(QStringLiteral("value")).toString(), row.value(QStringLiteral("unit")).toString()});
    }
    saved.sidebar = object.value(QStringLiteral("sidebar")).toBool();
    return saved;
}

QString savedFileName(const QString &name)
{
    QString clean;
    for (const QChar ch : name) {
        if (ch == QLatin1Char('/') || ch.unicode() == 0 || ch.category() == QChar::Other_Control)
            continue;
        clean.append(ch);
    }
    clean = clean.trimmed();
    if (clean.startsWith(QLatin1Char('.')))
        clean.remove(0, 1);
    while (clean.toUtf8().size() > 200)
        clean.chop(1);
    if (clean.isEmpty())
        clean = QStringLiteral("Search");
    return clean + QStringLiteral(".json");
}

} // namespace SearchLogic
