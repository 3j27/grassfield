#include "recents.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QSet>
#include <QXmlStreamReader>

#include <algorithm>
#include <cerrno>
#include <iterator>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

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

namespace
{
QHash<QString, Rename> &renames()
{
    static QHash<QString, Rename> map;
    return map;
}
} // namespace

void noteRenamed(const QString &from, const QString &to, const QDateTime &at)
{
    QHash<QString, Rename> &map = renames();
    for (auto it = map.begin(); it != map.end();) {
        // A chain keeps the time of its first rename (what was used before it went on to the last name).
        if (it.value().to == from)
            it.value().to = to;
        // Renamed back: nothing to follow.
        it = it.key() == it.value().to ? map.erase(it) : std::next(it);
    }
    if (from != to)
        map.insert(from, {to, at});
}

QHash<QString, Rename> renamed()
{
    return renames();
}

bool readList(const QString &file, QByteArray *out, qint64 max)
{
    out->clear();
    const QByteArray name = QFile::encodeName(file);
    struct stat st {};
    if (::stat(name.constData(), &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > max)
        return false;
    // O_NONBLOCK: a FIFO swapped in after the stat opens at once (and is refused below) instead of waiting for a writer.
    const int fd = ::open(name.constData(), O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0)
        return false;
    struct stat opened {};
    bool ok = ::fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_dev == st.st_dev && opened.st_ino == st.st_ino;
    // Room for the size seen and one byte more, grown up to one byte past the bound: a file that grew past the bound since
    // the stat is refused, not cut.
    QByteArray bytes(ok ? qMin(max, qint64(st.st_size)) + 1 : 0, Qt::Uninitialized);
    qint64 done = 0;
    while (ok) {
        if (done == bytes.size())
            bytes.resize(qMin(max + 1, 2 * done));
        const ssize_t n = ::read(fd, bytes.data() + done, size_t(bytes.size() - done));
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0)
            ok = false;
        else if (n == 0)
            break; // the end of the file: read whole
        else if ((done += n) > max)
            ok = false;
    }
    ::close(fd);
    if (!ok)
        return false;
    bytes.truncate(done);
    *out = bytes;
    return true;
}

} // namespace Recents

RecentsLoader::RecentsLoader(quint64 generation, const QString &file, const QHash<QString, Recents::Rename> &renames)
    : m_generation(generation)
    , m_file(file)
    , m_renames(renames)
{
}

void RecentsLoader::run()
{
    QStringList paths;
    QVariantList used;
    QByteArray xbel;
    if (Recents::readList(m_file, &xbel)) {
        const QList<Recents::Entry> entries = Recents::parse(xbel);
        QSet<QString> seen;
        for (const Recents::Entry &e : entries) {
            if (paths.size() >= Recents::kMaxItems)
                break;
            const auto rename = m_renames.constFind(e.path);
            const QString path = rename != m_renames.cend() && e.used <= rename->at ? rename->to : e.path;
            if (!seen.contains(path) && QFileInfo(path).isFile()) {
                seen.insert(path);
                paths.append(path);
                used.append(e.used);
            }
        }
    }
    emit loaded(m_generation, paths, used);
}
