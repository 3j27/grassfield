#include "desktopapps.h"

#include <QDir>
#include <QFile>
#include <QLocale>

namespace activity {

namespace {

// A desktop id is a file name: letters, digits and "._-" (the Desktop Entry specification), nothing that walks a path.
bool validId(const QString &id)
{
    if (id.isEmpty() || id.size() > 255 || id.startsWith(QLatin1Char('.')))
        return false;
    for (const QChar ch : id) {
        if (!(ch.isLetterOrNumber() || ch == QLatin1Char('.') || ch == QLatin1Char('_') || ch == QLatin1Char('-')))
            return false;
    }
    return true;
}

// A theme icon name, not a path (AD36: a file named by an entry is not decoded here).
bool themeIconName(const QString &icon)
{
    if (icon.isEmpty() || icon.size() > 255 || icon.contains(QLatin1Char('/')))
        return false;
    for (const QChar ch : icon) {
        if (!(ch.isLetterOrNumber() || ch == QLatin1Char('.') || ch == QLatin1Char('_') || ch == QLatin1Char('-') || ch == QLatin1Char('+')))
            return false;
    }
    return true;
}

} // namespace

DesktopApp parseDesktopApp(const QString &text, const QString &locale)
{
    const QString language = locale.section(QLatin1Char('_'), 0, 0);
    QString name, nameLanguage, nameLocale, icon;
    bool inEntry = false;
    for (const QString &raw : text.split(QLatin1Char('\n'))) {
        const QString line = raw.trimmed();
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = line == QLatin1String("[Desktop Entry]");
            continue;
        }
        if (!inEntry || line.startsWith(QLatin1Char('#')))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        if (key == QLatin1String("Name"))
            name = value;
        else if (!language.isEmpty() && key == QLatin1String("Name[") + language + QLatin1Char(']'))
            nameLanguage = value;
        else if (!locale.isEmpty() && key == QLatin1String("Name[") + locale + QLatin1Char(']'))
            nameLocale = value;
        else if (key == QLatin1String("Icon"))
            icon = value;
    }
    DesktopApp app;
    app.name = !nameLocale.isEmpty() ? nameLocale : !nameLanguage.isEmpty() ? nameLanguage : name;
    app.icon = themeIconName(icon) ? icon : QString();
    return app;
}

DesktopApps::DesktopApps(QStringList dirs, QString locale)
    : m_dirs(std::move(dirs))
    , m_locale(std::move(locale))
{
}

DesktopApps DesktopApps::fromEnvironment()
{
    QStringList dirs;
    const QString home = qEnvironmentVariable("XDG_DATA_HOME");
    dirs << (home.isEmpty() ? QDir::homePath() + QStringLiteral("/.local/share") : home);
    const QString system = qEnvironmentVariable("XDG_DATA_DIRS");
    dirs << (system.isEmpty() ? QStringList{QStringLiteral("/usr/local/share"), QStringLiteral("/usr/share")}
                              : system.split(QLatin1Char(':'), Qt::SkipEmptyParts));
    return DesktopApps(dirs, QLocale().name());
}

const DesktopApp &DesktopApps::app(const QString &desktopId)
{
    auto it = m_cache.constFind(desktopId);
    if (it != m_cache.constEnd())
        return *it;
    DesktopApp found;
    if (validId(desktopId)) {
        for (const QString &dir : std::as_const(m_dirs)) {
            QFile f(dir + QStringLiteral("/applications/") + desktopId + QStringLiteral(".desktop"));
            if (!f.open(QIODevice::ReadOnly))
                continue;
            if (f.size() <= 256 * 1024)
                found = parseDesktopApp(QString::fromUtf8(f.read(256 * 1024)), m_locale);
            break; // the first directory that has the entry wins, as the specification says
        }
    }
    return *m_cache.insert(desktopId, found);
}

} // namespace activity
