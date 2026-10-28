// The app of a launch's unit (AM10, AM17): uwsm names the unit after the desktop id it launched (A7), so the row of a
// process in it takes that entry's icon and, for the search, its name. Read once per id and kept; an id with no entry (a
// command launched without one) has neither.
#pragma once

#include <QHash>
#include <QString>
#include <QStringList>

namespace activity {

struct DesktopApp {
    QString name; // Name, in the session's language when the entry has it
    QString icon; // a theme icon name; "" when the entry names a file (the generic glyph then, ADR-0038 AD36)
};

// The [Desktop Entry] group's Name (Name[<lang>_<COUNTRY>], Name[<lang>], Name) and Icon of one entry's text.
DesktopApp parseDesktopApp(const QString &text, const QString &locale);

class DesktopApps
{
public:
    // `dirs`: the XDG data directories, first wins (XDG_DATA_HOME, then XDG_DATA_DIRS); `locale`: "fr_FR" and the like.
    DesktopApps(QStringList dirs, QString locale);
    // From the environment: $XDG_DATA_HOME (or ~/.local/share), then $XDG_DATA_DIRS (or /usr/local/share:/usr/share).
    static DesktopApps fromEnvironment();

    const DesktopApp &app(const QString &desktopId);

private:
    QStringList m_dirs;
    QString m_locale;
    QHash<QString, DesktopApp> m_cache;
};

} // namespace activity
