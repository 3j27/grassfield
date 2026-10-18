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
    return key == SortKey::Date || key == SortKey::Size;
}

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
        primary = three(a.modified, b.modified);
        break;
    case SortKey::Size:
        primary = three(a.size, b.size);
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
