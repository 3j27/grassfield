#include "pacman.h"

#include "catalog.h"
#include "childprocess.h"

#include <QDateTime>
#include <QRegularExpression>

#include <cmath>

namespace grassfield::store {

bool isStoreRepository(const QString &repo)
{
    return repo == QLatin1String("core") || repo == QLatin1String("extra") || repo == QLatin1String("multilib")
        || repo == QLatin1String("omarchy");
}

QList<SyncPackage> parseSyncList(const QByteArray &pacmanSl)
{
    // "extra gimp 3.0.4-1", then " [installed]" or " [installed: 3.0.2-1]" when a version of it is installed.
    QList<SyncPackage> out;
    for (const QByteArray &raw : pacmanSl.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(' ');
        if (f.size() < 3)
            continue;
        SyncPackage p;
        p.repo = QString::fromUtf8(f.at(0));
        p.name = QString::fromUtf8(f.at(1));
        p.version = QString::fromUtf8(f.at(2));
        p.installed = f.size() > 3 && f.at(3).startsWith("[installed");
        if (isStoreRepository(p.repo) && isPackageName(p.name))
            out.append(p);
    }
    return out;
}

QSet<QString> parseNameList(const QByteArray &out)
{
    QSet<QString> names;
    for (const QByteArray &raw : out.split('\n')) {
        const QString name = QString::fromUtf8(raw.trimmed());
        if (isPackageName(name))
            names.insert(name);
    }
    return names;
}

qint64 parseSize(const QString &text)
{
    static const QRegularExpression re(QStringLiteral(R"(\A([0-9]+(?:\.[0-9]+)?) (B|KiB|MiB|GiB|TiB)\z)"));
    const auto m = re.match(text.trimmed());
    if (!m.hasMatch())
        return -1;
    const QString unit = m.captured(2);
    const int power = unit == QLatin1String("B") ? 0 : unit == QLatin1String("KiB") ? 1 : unit == QLatin1String("MiB") ? 2 : unit == QLatin1String("GiB") ? 3 : 4;
    return qint64(std::llround(m.captured(1).toDouble() * std::pow(1024.0, power)));
}

QDate parseBuildDate(const QString &text)
{
    // LC_ALL=C's %c: "Thu Oct 15 08:27:03 2026", the day padded with a space below 10. The day is all the Store shows.
    return QDateTime::fromString(text.simplified(), QStringLiteral("ddd MMM d HH:mm:ss yyyy")).date();
}

std::optional<PackageInfo> parsePackageInfo(const QByteArray &pacmanSi)
{
    // "Key            : value" lines; a value that goes on is indented under it. The first record only.
    PackageInfo info;
    QString key;
    for (const QByteArray &raw : pacmanSi.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (line.trimmed().isEmpty()) {
            if (!info.name.isEmpty())
                break;
            continue;
        }
        const int colon = line.indexOf(QStringLiteral(" : "));
        QString value;
        if (colon > 0 && !line.at(0).isSpace()) {
            key = line.left(colon).trimmed();
            value = line.mid(colon + 3).trimmed();
        } else {
            value = line.trimmed(); // continuation
        }
        if (key == QLatin1String("Repository"))
            info.repo = value;
        else if (key == QLatin1String("Name"))
            info.name = value;
        else if (key == QLatin1String("Version"))
            info.version = value;
        else if (key == QLatin1String("Description"))
            info.description = (info.description.isEmpty() ? QString() : info.description + QLatin1Char(' ')) + value;
        else if (key == QLatin1String("URL"))
            info.url = isHttpsUrl(value) ? value : QString();
        else if (key == QLatin1String("Licenses") && value != QLatin1String("None"))
            info.licenses += value.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        else if (key == QLatin1String("Download Size"))
            info.downloadSize = parseSize(value);
        else if (key == QLatin1String("Installed Size"))
            info.installedSize = parseSize(value);
        else if (key == QLatin1String("Build Date"))
            info.buildDate = parseBuildDate(value);
    }
    if (!isPackageName(info.name))
        return std::nullopt;
    info.description = cleanPlainText(info.description, 200, false);
    return info;
}

Pacman::Pacman(const QString &program)
    : m_program(program)
{
}

QList<SyncPackage> Pacman::syncList() const
{
    const ChildResult r = runChild(m_program, {QStringLiteral("-Sl")});
    return r.ok() ? parseSyncList(r.out) : QList<SyncPackage>{};
}

QSet<QString> Pacman::explicitlyInstalled() const
{
    const ChildResult r = runChild(m_program, {QStringLiteral("-Qqe")});
    return r.ok() ? parseNameList(r.out) : QSet<QString>{};
}

QSet<QString> Pacman::foreign() const
{
    // pacman -Qqm exits 1 when there is none.
    const ChildResult r = runChild(m_program, {QStringLiteral("-Qqm")});
    return r.started && !r.timedOut && !r.overflow ? parseNameList(r.out) : QSet<QString>{};
}

std::optional<PackageInfo> Pacman::info(const QString &package) const
{
    if (!isPackageName(package))
        return std::nullopt;
    const ChildResult r = runChild(m_program, {QStringLiteral("-Si"), QStringLiteral("--"), package});
    return r.ok() ? parsePackageInfo(r.out) : std::nullopt;
}

} // namespace grassfield::store
