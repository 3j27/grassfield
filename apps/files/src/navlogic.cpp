#include "navlogic.h"

#include <QDir>
#include <QRegularExpression>

#include <algorithm>

namespace NavLogic
{

CompletionTarget completionTarget(const QString &text, const QString &base, const QString &home)
{
    CompletionTarget out;
    if (text.isEmpty() || text.contains(QLatin1Char('\0')))
        return out;
    // A URL other than file:// is completed by nobody (remote folders are listed by KIO, never synchronously here).
    if (text.contains(QStringLiteral("://")) && !text.startsWith(QStringLiteral("file://")))
        return out;
    const QString t = text.startsWith(QStringLiteral("file://")) ? QUrl(text).toLocalFile() : text;
    const int slash = t.lastIndexOf(QLatin1Char('/'));
    const int typedSlash = text.lastIndexOf(QLatin1Char('/'));
    out.typedFolder = typedSlash >= 0 ? text.left(typedSlash + 1) : QString();
    out.prefix = slash >= 0 ? t.mid(slash + 1) : t;
    QString folder = slash >= 0 ? t.left(slash + 1) : QString();
    if (folder == QStringLiteral("~/") || folder.startsWith(QStringLiteral("~/")))
        folder = home + folder.mid(1);
    else if (t == QStringLiteral("~"))
        return out;
    if (folder.isEmpty())
        folder = base;
    else if (!folder.startsWith(QLatin1Char('/')))
        folder = base.isEmpty() ? QString() : base + QLatin1Char('/') + folder;
    if (folder.isEmpty())
        return out;
    out.folder = QDir::cleanPath(folder);
    return out;
}

QStringList folderMatches(QStringList names, const QString &prefix, bool showHidden, int max)
{
    const bool hidden = showHidden || prefix.startsWith(QLatin1Char('.'));
    QStringList out;
    for (const QString &name : std::as_const(names)) {
        if (name == QStringLiteral(".") || name == QStringLiteral(".."))
            continue;
        if (!hidden && name.startsWith(QLatin1Char('.')))
            continue;
        if (name.startsWith(prefix, Qt::CaseInsensitive))
            out.append(name);
    }
    std::sort(out.begin(), out.end(), [](const QString &a, const QString &b) {
        const int c = a.compare(b, Qt::CaseInsensitive);
        return c != 0 ? c < 0 : a < b;
    });
    if (max >= 0 && out.size() > max)
        out.resize(max);
    return out;
}

QString completedText(const CompletionTarget &target, const QString &match)
{
    return target.typedFolder + match + QLatin1Char('/');
}

QUrl serverUrl(const QString &text)
{
    QString t = text.trimmed();
    if (t.isEmpty())
        return {};
    if (!t.contains(QStringLiteral("://"))) {
        // "trash:/", "file:/etc": another kind of location, not a host ("nas:445/share" is a host and its port).
        static const QRegularExpression kSchemeOnly(QStringLiteral("^[A-Za-z][A-Za-z0-9+.-]*:/"));
        if (kSchemeOnly.match(t).hasMatch())
            return {};
        t.prepend(QStringLiteral("smb://"));
    }
    QUrl url(t, QUrl::StrictMode);
    if (!url.isValid())
        return {};
    QString scheme = url.scheme().toLower();
    if (scheme == QLatin1String("http"))
        scheme = QStringLiteral("webdav");
    else if (scheme == QLatin1String("https"))
        scheme = QStringLiteral("webdavs");
    static const QStringList kSchemes = {QStringLiteral("smb"), QStringLiteral("sftp"), QStringLiteral("fish"), QStringLiteral("ftp"),
                                         QStringLiteral("ftps"), QStringLiteral("webdav"), QStringLiteral("webdavs"), QStringLiteral("nfs")};
    if (!kSchemes.contains(scheme))
        return {};
    if (url.host().isEmpty() || url.host().contains(QLatin1Char(' ')))
        return {};
    url.setScheme(scheme);
    url.setPassword(QString());
    if (url.path().isEmpty())
        url.setPath(QStringLiteral("/"));
    return url;
}

QStringList pushRecent(QStringList list, const QString &item, int max)
{
    if (item.isEmpty())
        return list;
    list.removeAll(item);
    list.prepend(item);
    if (list.size() > max)
        list.resize(max);
    return list;
}

QString placeShortcut(const QString &kind, const QString &path, const QString &home, const QStringList &xdg)
{
    if (kind == QLatin1String("recents"))
        return QStringLiteral("Ctrl+Shift+F");
    if (kind == QLatin1String("applications"))
        return QStringLiteral("Ctrl+Shift+A");
    if (kind == QLatin1String("network"))
        return QStringLiteral("Ctrl+Shift+K");
    if (path.isEmpty())
        return {};
    const QString clean = QDir::cleanPath(path);
    if (kind == QLatin1String("volume") && clean == QStringLiteral("/"))
        return QStringLiteral("Ctrl+Shift+C");
    if (clean == QDir::cleanPath(home))
        return QStringLiteral("Ctrl+Shift+H");
    static const char *kShortcuts[] = {"Ctrl+Shift+D", "Ctrl+Shift+O", "Ctrl+Alt+L"};
    for (int i = 0; i < 3 && i < xdg.size(); ++i) {
        // A missing XDG folder falls back to the home folder (xdg-user-dirs): never give home a second shortcut.
        if (!xdg.at(i).isEmpty() && QDir::cleanPath(xdg.at(i)) != QDir::cleanPath(home) && clean == QDir::cleanPath(xdg.at(i)))
            return QString::fromLatin1(kShortcuts[i]);
    }
    return {};
}

} // namespace NavLogic
