#include "recents.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QXmlStreamReader>

#include <algorithm>

namespace Recents
{

namespace
{
QDateTime later(const QDateTime &a, const QDateTime &b)
{
    if (!a.isValid())
        return b;
    if (!b.isValid())
        return a;
    return a < b ? b : a;
}

QDateTime timeOf(const QXmlStreamAttributes &attributes, const char *name)
{
    return QDateTime::fromString(attributes.value(QLatin1String(name)).toString(), Qt::ISODateWithMs);
}
} // namespace

QList<Entry> parse(const QByteArray &xbel)
{
    QXmlStreamReader xml(xbel);
    QHash<QString, QDateTime> latest;
    QString path;
    QDateTime used;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            if (xml.name() == QLatin1String("bookmark")) {
                const QUrl url(xml.attributes().value(QLatin1String("href")).toString());
                path = url.isLocalFile() && QDir::isAbsolutePath(url.toLocalFile()) ? QDir::cleanPath(url.toLocalFile()) : QString();
                used = later(timeOf(xml.attributes(), "modified"), timeOf(xml.attributes(), "visited"));
            } else if (xml.name() == QLatin1String("application") && !path.isEmpty()) {
                // <bookmark:application name="…" modified="…" count="…"/> inside the bookmark's metadata.
                used = later(used, timeOf(xml.attributes(), "modified"));
            }
        } else if (xml.isEndElement() && xml.name() == QLatin1String("bookmark")) {
            if (!path.isEmpty() && used.isValid())
                latest[path] = later(latest.value(path), used);
            path.clear();
            used = QDateTime();
        }
    }
    // A truncated or broken document keeps what was read before the error.
    QList<Entry> out;
    out.reserve(latest.size());
    for (auto it = latest.cbegin(); it != latest.cend(); ++it)
        out.append({it.key(), it.value()});
    std::sort(out.begin(), out.end(), [](const Entry &a, const Entry &b) { return a.used != b.used ? a.used > b.used : a.path < b.path; });
    return out;
}

QString scheme()
{
    return QStringLiteral("grassfield-recents");
}

QUrl locationUrl()
{
    QUrl url;
    url.setScheme(scheme());
    url.setPath(QStringLiteral("/"));
    return url;
}

bool isRecentsUrl(const QUrl &url)
{
    return url.scheme() == scheme();
}

QString xbelPath()
{
    QString data = qEnvironmentVariable("XDG_DATA_HOME");
    if (data.isEmpty() || !QDir::isAbsolutePath(data))
        data = QDir::homePath() + QStringLiteral("/.local/share");
    return data + QStringLiteral("/recently-used.xbel");
}

} // namespace Recents

RecentsLoader::RecentsLoader(quint64 generation, const QString &file)
    : m_generation(generation)
    , m_file(file)
{
}

void RecentsLoader::run()
{
    QStringList paths;
    QVariantList used;
    QFile f(m_file);
    // The file is a few hundred kilobytes; anything far larger is not a recently-used list.
    constexpr qint64 kMaxFileSize = 32 * 1024 * 1024;
    if (f.size() <= kMaxFileSize && f.open(QIODevice::ReadOnly)) {
        const QList<Recents::Entry> entries = Recents::parse(f.readAll());
        for (const Recents::Entry &e : entries) {
            if (paths.size() >= Recents::kMaxItems)
                break;
            if (QFileInfo(e.path).isFile()) {
                paths.append(e.path);
                used.append(e.used);
            }
        }
    }
    emit loaded(m_generation, paths, used);
}
