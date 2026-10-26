#include "filelogic.h"

#include <QCollator>
#include <QCoreApplication>

#include <cmath>

namespace FileLogic
{

namespace
{
QString tr(const char *text)
{
    return QCoreApplication::translate("FileLogic", text);
}

template<typename T>
int three(const T &a, const T &b)
{
    return a < b ? -1 : (b < a ? 1 : 0);
}

// Locale number with `decimals` digits, trailing zeros (and a dangling separator) removed.
QString trimmedNumber(double value, int decimals, const QLocale &locale)
{
    QString s = locale.toString(value, 'f', decimals);
    if (decimals > 0) {
        const QString dot = locale.decimalPoint();
        const int at = s.lastIndexOf(dot);
        if (at >= 0) {
            int end = s.size();
            while (end > at + dot.size() && s.at(end - 1) == locale.zeroDigit().at(0))
                --end;
            if (end == at + dot.size())
                end = at;
            s.truncate(end);
        }
    }
    return s;
}
} // namespace

bool defaultDescending(SortKey key)
{
    return key == SortKey::Date || key == SortKey::Size || key == SortKey::Created || key == SortKey::Opened;
}

namespace
{
// Items without a value come after those with one, in both directions: 0 when both or neither have one.
int missingLast(bool aMissing, bool bMissing)
{
    return aMissing == bMissing ? 0 : (aMissing ? 1 : -1);
}

int compareDates(const QDateTime &a, const QDateTime &b)
{
    return three(a, b);
}

// The first tag's place: colour tags by palette index, then the other tags (equal here, then by name).
int tagRank(const QString &tag)
{
    static const QStringList colors = {QStringLiteral("Red"), QStringLiteral("Orange"), QStringLiteral("Yellow"), QStringLiteral("Green"),
                                       QStringLiteral("Blue"), QStringLiteral("Purple"), QStringLiteral("Gray")};
    const int i = colors.indexOf(tag);
    return i >= 0 ? i : int(colors.size());
}
} // namespace

int compareEntries(const SortEntry &a, const SortEntry &b, SortKey key, bool descending, bool foldersFirst, const QCollator &collator)
{
    if (foldersFirst && a.isDir != b.isDir)
        return a.isDir ? -1 : 1;
    int primary = 0;
    switch (key) {
    case SortKey::Kind:
        primary = collator.compare(a.kind, b.kind);
        break;
    case SortKey::Date:
        primary = compareDates(a.modified, b.modified);
        break;
    case SortKey::Size:
        primary = three(a.size, b.size);
        break;
    case SortKey::Created:
    case SortKey::Opened: {
        const QDateTime &da = key == SortKey::Created ? a.created : a.opened;
        const QDateTime &db = key == SortKey::Created ? b.created : b.opened;
        if (const int m = missingLast(!da.isValid(), !db.isValid()))
            return m;
        primary = compareDates(da, db);
        break;
    }
    case SortKey::Tags:
        if (const int m = missingLast(a.tags.isEmpty(), b.tags.isEmpty()))
            return m;
        if (!a.tags.isEmpty()) {
            primary = three(tagRank(a.tags.first()), tagRank(b.tags.first()));
            if (primary == 0)
                primary = collator.compare(a.tags.first(), b.tags.first());
        }
        break;
    case SortKey::Application:
        if (const int m = missingLast(a.application.isEmpty(), b.application.isEmpty()))
            return m;
        primary = collator.compare(a.application, b.application);
        break;
    case SortKey::Name:
        primary = collator.compare(a.name, b.name);
        if (primary == 0)
            primary = QString::compare(a.name, b.name);
        return descending ? -primary : primary;
    }
    if (primary != 0)
        return descending ? -primary : primary;
    const int byName = collator.compare(a.name, b.name);
    return byName != 0 ? byName : QString::compare(a.name, b.name);
}

namespace
{
// Kind categories (the Finder's Group By Kind), matched against the MIME type and its ancestors in order.
QString kindCategory(const SortEntry &e)
{
    if (e.isDir)
        return tr("Folders");
    struct Rule {
        const char *title;
        QStringList exact;
        QStringList prefixes;
    };
    static const QList<Rule> rules = {
        {QT_TRANSLATE_NOOP("FileLogic", "PDF Documents"), {QStringLiteral("application/pdf")}, {}},
        {QT_TRANSLATE_NOOP("FileLogic", "Presentations"),
         {QStringLiteral("application/vnd.oasis.opendocument.presentation"), QStringLiteral("application/vnd.ms-powerpoint"),
          QStringLiteral("application/x-iwork-keynote-sffkey")},
         {QStringLiteral("application/vnd.openxmlformats-officedocument.presentationml.")}},
        {QT_TRANSLATE_NOOP("FileLogic", "Spreadsheets"),
         {QStringLiteral("application/vnd.oasis.opendocument.spreadsheet"), QStringLiteral("application/vnd.ms-excel"),
          QStringLiteral("text/csv"), QStringLiteral("text/tab-separated-values")},
         {QStringLiteral("application/vnd.openxmlformats-officedocument.spreadsheetml.")}},
        {QT_TRANSLATE_NOOP("FileLogic", "Images"), {}, {QStringLiteral("image/")}},
        {QT_TRANSLATE_NOOP("FileLogic", "Movies"), {}, {QStringLiteral("video/")}},
        {QT_TRANSLATE_NOOP("FileLogic", "Music"), {}, {QStringLiteral("audio/")}},
        {QT_TRANSLATE_NOOP("FileLogic", "Applications"),
         {QStringLiteral("application/x-desktop"), QStringLiteral("application/x-executable"), QStringLiteral("application/vnd.appimage"),
          QStringLiteral("application/x-pie-executable")},
         {}},
        {QT_TRANSLATE_NOOP("FileLogic", "Archives"),
         {QStringLiteral("application/zip"), QStringLiteral("application/x-tar"), QStringLiteral("application/gzip"),
          QStringLiteral("application/x-7z-compressed"), QStringLiteral("application/x-xz"), QStringLiteral("application/x-bzip2"),
          QStringLiteral("application/zstd"), QStringLiteral("application/vnd.rar"), QStringLiteral("application/x-rar"),
          QStringLiteral("application/x-compressed-tar"), QStringLiteral("application/x-cd-image")},
         {}},
        {QT_TRANSLATE_NOOP("FileLogic", "Documents"),
         {QStringLiteral("application/rtf"), QStringLiteral("application/msword"), QStringLiteral("application/vnd.oasis.opendocument.text"),
          QStringLiteral("application/epub+zip"), QStringLiteral("text/plain")},
         {QStringLiteral("application/vnd.openxmlformats-officedocument.wordprocessingml."), QStringLiteral("text/")}},
    };
    for (const QString &type : e.mimeTypes) {
        for (const Rule &rule : rules) {
            if (rule.exact.contains(type))
                return tr(rule.title);
            for (const QString &prefix : rule.prefixes) {
                if (type.startsWith(prefix))
                    return tr(rule.title);
            }
        }
    }
    return QString();
}

Group dateGroup(const QDateTime &when, const QDateTime &now, const QLocale &locale)
{
    if (!when.isValid())
        return {100000, tr("Unknown")};
    const QDate day = when.toLocalTime().date();
    const QDate today = now.toLocalTime().date();
    const qint64 ago = day.daysTo(today);
    if (ago <= 0)
        return {0, tr("Today")};
    if (ago == 1)
        return {1, tr("Yesterday")};
    if (ago <= 7)
        return {2, tr("Previous 7 Days")};
    if (ago <= 30)
        return {3, tr("Previous 30 Days")};
    if (day.year() == today.year())
        return {4 + (12 - day.month()), locale.standaloneMonthName(day.month())};
    return {100 + (today.year() - day.year()), QString::number(day.year())};
}

Group sizeGroup(const SortEntry &e)
{
    if (e.isDir || e.size < 0)
        return {10, tr("Folders")};
    if (e.size >= 1000LL * 1000 * 1000)
        return {0, tr("More than 1 GB")};
    if (e.size >= 100LL * 1000 * 1000)
        return {1, tr("100 MB to 1 GB")};
    if (e.size >= 1000LL * 1000)
        return {2, tr("1 MB to 100 MB")};
    if (e.size >= 100LL * 1000)
        return {3, tr("100 KB to 1 MB")};
    if (e.size > 0)
        return {4, tr("Less than 100 KB")};
    return {5, tr("Zero bytes")};
}
} // namespace

Group groupOf(const SortEntry &e, GroupBy by, const QDateTime &now, const QLocale &locale)
{
    switch (by) {
    case GroupBy::None:
        return {};
    case GroupBy::Name: {
        const QString folded = foldForMatch(e.name.trimmed().left(2)).left(1).toUpper();
        if (folded.isEmpty() || !folded.at(0).isLetter())
            return {0, QStringLiteral("#")};
        return {1, folded};
    }
    case GroupBy::Kind: {
        const QString category = kindCategory(e);
        return category.isEmpty() ? Group{1, tr("Other")} : Group{0, category};
    }
    case GroupBy::Application:
        if (e.isDir)
            return {0, tr("Folders")};
        return e.application.isEmpty() ? Group{2, tr("Other")} : Group{1, e.application};
    case GroupBy::Opened:
        return dateGroup(e.opened, now, locale);
    case GroupBy::Modified:
        return dateGroup(e.modified, now, locale);
    case GroupBy::Created:
        return dateGroup(e.created, now, locale);
    case GroupBy::Size:
        return sizeGroup(e);
    case GroupBy::Tags:
        if (e.tags.isEmpty())
            return {20, tr("No Tags")};
        return {tagRank(e.tags.first()), QCoreApplication::translate("Tags", e.tags.first().toUtf8().constData())};
    }
    return {};
}

int compareGroups(const Group &a, const Group &b, const QCollator &collator)
{
    if (a.rank != b.rank)
        return a.rank < b.rank ? -1 : 1;
    return collator.compare(a.title, b.title);
}

QString formatSize(qint64 bytes, const QLocale &locale)
{
    if (bytes < 0)
        return QStringLiteral("--");
    if (bytes == 0)
        return tr("Zero bytes");
    if (bytes == 1)
        return tr("1 byte");
    if (bytes < 1000)
        return tr("%1 bytes").arg(locale.toString(bytes));

    static const char *const units[] = {QT_TRANSLATE_NOOP("FileLogic", "%1 KB"), QT_TRANSLATE_NOOP("FileLogic", "%1 MB"),
                                        QT_TRANSLATE_NOOP("FileLogic", "%1 GB"), QT_TRANSLATE_NOOP("FileLogic", "%1 TB"),
                                        QT_TRANSLATE_NOOP("FileLogic", "%1 PB")};
    constexpr int unitCount = 5;
    int unit = 0;
    double value = double(bytes) / 1000.0;
    while (value >= 1000.0 && unit < unitCount - 1) {
        value /= 1000.0;
        ++unit;
    }
    // Kilobytes are whole numbers; larger units keep three significant digits.
    int decimals = unit == 0 ? 0 : (value < 10 ? 2 : (value < 100 ? 1 : 0));
    const double scale = std::pow(10.0, decimals);
    double rounded = std::round(value * scale) / scale;
    if (rounded >= 1000.0 && unit < unitCount - 1) {
        // 999.5 KB rounds up into the next unit.
        ++unit;
        rounded = rounded / 1000.0;
        decimals = 2;
    }
    return tr(units[unit]).arg(trimmedNumber(rounded, decimals, locale));
}

QString formatDate(const QDateTime &when, const QDateTime &now, const QLocale &locale)
{
    if (!when.isValid())
        return QStringLiteral("--");
    const QString time = locale.toString(when.time(), QLocale::ShortFormat);
    const qint64 days = when.date().daysTo(now.date());
    if (days == 0)
        return tr("Today at %1").arg(time);
    if (days == 1)
        return tr("Yesterday at %1").arg(time);
    return tr("%1 at %2").arg(locale.toString(when.date(), QLocale::ShortFormat), time);
}

QList<Segment> pathSegments(const QUrl &url, const QString &homePath, const QString &rootLabel, const QString &trashLabel)
{
    QList<Segment> out;
    QString path = url.path();
    while (path.size() > 1 && path.endsWith(QLatin1Char('/')))
        path.chop(1);
    if (path.isEmpty())
        path = QStringLiteral("/");

    QString base; // path of the first segment
    QUrl first;
    if (url.isLocalFile()) {
        QString home = homePath;
        while (home.size() > 1 && home.endsWith(QLatin1Char('/')))
            home.chop(1);
        if (!home.isEmpty() && home != QLatin1String("/") && (path == home || path.startsWith(home + QLatin1Char('/')))) {
            base = home;
            first = QUrl::fromLocalFile(home);
            out.append({home.section(QLatin1Char('/'), -1), first});
        } else {
            base = QStringLiteral("/");
            first = QUrl::fromLocalFile(QStringLiteral("/"));
            out.append({rootLabel, first});
        }
    } else {
        base = QStringLiteral("/");
        first = url;
        first.setPath(QStringLiteral("/"));
        first.setQuery(QString());
        first.setFragment(QString());
        QString label;
        if (url.scheme() == QLatin1String("trash"))
            label = trashLabel;
        else if (!url.host().isEmpty())
            label = url.host();
        else
            label = url.scheme() + QLatin1Char(':');
        out.append({label, first});
    }

    const QString rest = path.mid(base.size());
    const QStringList parts = rest.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    QString current = base == QLatin1String("/") ? QString() : base;
    for (const QString &part : parts) {
        current += QLatin1Char('/') + part;
        QUrl u = first;
        u.setPath(current);
        out.append({part, u});
    }
    return out;
}

QString displayName(const QString &name)
{
    QString out;
    out.reserve(name.size());
    bool inBreak = false;
    for (const QChar c : name) {
        const ushort u = c.unicode();
        if (u == '\r' || u == '\n') {
            if (!inBreak)
                out += QChar(0x23CE);
            inBreak = true;
            continue;
        }
        inBreak = false;
        if ((u >= 0x202A && u <= 0x202E) || (u >= 0x2066 && u <= 0x2069) || u == 0x2028 || u == 0x2029)
            out += QStringLiteral("<U+%1>").arg(u, 4, 16, QLatin1Char('0')).toUpper();
        else
            out += c;
    }
    return out;
}

bool sameName(const QString &a, const QString &b)
{
    return a == b || a.normalized(QString::NormalizationForm_C) == b.normalized(QString::NormalizationForm_C);
}

QString equivalentName(const QStringList &names, const QString &name)
{
    for (const QString &n : names) {
        if (n != name && sameName(n, name))
            return n;
    }
    return {};
}

QString trashInfoOriginalPath(const QByteArray &trashinfo)
{
    bool inGroup = false;
    for (const QByteArray &raw : trashinfo.split('\n')) {
        const QByteArray line = raw.trimmed();
        if (line.startsWith('[')) {
            inGroup = line == "[Trash Info]";
            continue;
        }
        if (inGroup && line.startsWith("Path=")) {
            const QString path = QUrl::fromPercentEncoding(line.mid(5));
            return path.startsWith(QLatin1Char('/')) ? path : QString();
        }
    }
    return {};
}

QString foldForMatch(const QString &text)
{
    const QString decomposed = text.normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar c : decomposed) {
        const QChar::Category cat = c.category();
        if (cat != QChar::Mark_NonSpacing && cat != QChar::Mark_SpacingCombining && cat != QChar::Mark_Enclosing)
            out.append(c);
    }
    return out.toCaseFolded().normalized(QString::NormalizationForm_C);
}

bool nameMatchesFilter(const QString &name, const QString &filter)
{
    return foldForMatch(name).contains(foldForMatch(filter));
}

bool isValidFileName(const QString &name)
{
    if (name.isEmpty() || name == QLatin1String(".") || name == QLatin1String(".."))
        return false;
    if (name.contains(QLatin1Char('/')) || name.contains(QChar(0)))
        return false;
    return name.toUtf8().size() <= 255;
}

int baseNameLength(const QString &name, bool isDir)
{
    if (isDir)
        return name.size();
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    return dot > 0 ? dot : name.size();
}

QString uniqueName(const QString &base, const std::function<bool(const QString &)> &exists)
{
    if (!exists(base))
        return base;
    for (int n = 2;; ++n) {
        const QString candidate = base + QLatin1Char(' ') + QString::number(n);
        if (!exists(candidate))
            return candidate;
    }
}

QString duplicateName(const QString &name, bool isDir, const QString &copyWord, const std::function<bool(const QString &)> &exists)
{
    const int stem = baseNameLength(name, isDir);
    const QString head = name.left(stem) + QLatin1Char(' ') + copyWord;
    const QString ext = name.mid(stem);
    if (!exists(head + ext))
        return head + ext;
    for (int n = 2;; ++n) {
        const QString candidate = head + QLatin1Char(' ') + QString::number(n) + ext;
        if (!exists(candidate))
            return candidate;
    }
}

bool hiddenNetworkEntry(const QUrl &item, const QUrl &target)
{
    if (item.scheme() != QLatin1String("remote"))
        return false;
    // kio-extras' remoteview entry afc-network.desktop (URL=afc:/): matched by its target, or by its name when a
    // listing does not carry the target.
    return target.scheme() == QLatin1String("afc") || item.fileName().startsWith(QLatin1String("afc-network"));
}

} // namespace FileLogic
