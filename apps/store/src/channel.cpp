#include "channel.h"

#include <QRegularExpression>

namespace grassfield::store {

namespace {

QUrl cleanBase(const QString &text)
{
    QString s = text.trimmed();
    while (s.endsWith(QLatin1Char('/')))
        s.chop(1);
    const QUrl url(s, QUrl::StrictMode);
    if (!url.isValid() || url.scheme() != QLatin1String("https") || url.host().isEmpty() || url.hasQuery() || url.hasFragment()
        || !url.userInfo().isEmpty())
        return {};
    return url;
}

QUrl join(const QUrl &base, const QString &path)
{
    QUrl url = base;
    url.setPath(base.path() + QLatin1Char('/') + path);
    return url;
}

} // namespace

std::optional<Channel> channelFromConf(const QByteArray &grassfieldConf)
{
    static const QRegularExpression server(QStringLiteral(R"(\A\s*Server\s*=\s*(\S+)\s*\z)"));
    static const QRegularExpression shape(QStringLiteral(R"(\A(.+)/(stable|beta)/\$arch\z)"));
    for (const QByteArray &raw : grassfieldConf.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (line.trimmed().startsWith(QLatin1Char('#')))
            continue;
        const auto m = server.match(line);
        if (!m.hasMatch())
            continue;
        // The first Server is the primary; only its shape decides.
        const auto s = shape.match(m.captured(1));
        if (!s.hasMatch())
            return std::nullopt;
        const QUrl base = cleanBase(s.captured(1));
        if (base.isEmpty())
            return std::nullopt;
        return Channel{s.captured(2), base};
    }
    return std::nullopt;
}

QString buildBase(const QByteArray &repositoryConf)
{
    // One KEY=value per line, no quotes, no expansion (packaging/pacman/repository.conf); the last assignment wins.
    QString base;
    for (const QByteArray &raw : repositoryConf.split('\n')) {
        const QByteArray line = raw.trimmed();
        if (line.startsWith("GRASSFIELD_REPO_BASE="))
            base = QString::fromUtf8(line.mid(int(qstrlen("GRASSFIELD_REPO_BASE="))));
    }
    return base;
}

Channel defaultChannel(const QString &buildBase)
{
    return Channel{QStringLiteral("stable"), cleanBase(buildBase)};
}

bool fetchable(const Channel &channel)
{
    const QString host = channel.base.host();
    return channel.base.isValid() && channel.base.scheme() == QLatin1String("https") && !host.isEmpty()
        && host != QLatin1String("invalid") && !host.endsWith(QLatin1String(".invalid"));
}

QUrl catalogUrl(const Channel &channel, const QString &arch)
{
    return join(channel.base, channel.name + QLatin1Char('/') + arch + QStringLiteral("/grassfield-catalog.v1.json"));
}

QUrl signatureUrl(const QUrl &file)
{
    QUrl url = file;
    url.setPath(file.path() + QStringLiteral(".sig"));
    return url;
}

QUrl iconUrl(const Channel &channel, const QString &sha256, const QString &arch)
{
    return join(channel.base, channel.name + QLatin1Char('/') + arch + QStringLiteral("/catalog/") + sha256 + QStringLiteral(".png"));
}

bool requestAllowed(const QUrl &url, bool devPlumbing)
{
    if (!url.isValid() || !url.userInfo().isEmpty())
        return false;
    if (url.scheme() == QLatin1String("https"))
        return !url.host().isEmpty();
    return devPlumbing && url.isLocalFile();
}

} // namespace grassfield::store
