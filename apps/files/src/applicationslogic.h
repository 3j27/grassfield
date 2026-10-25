#pragma once

#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <functional>

// The Applications location of Files (macOS: the Applications folder in the Finder sidebar): the desktop entries the user
// sees, with the same rules as the shell's Apps grid (shell/launchpad/hidden-entries.sh, held to it by
// tests/unit/files/tst_applications.cpp). Qt Core only. The location is virtual and read-only: its items are never files
// to rename, move or delete, and opening one starts the application (FilesApp::launchApplication).
//
// Rules, per desktop entry id (the file name without ".desktop", subfolders joined with "-"; the highest-priority
// applications directory wins, also when it hides the entry):
//   - only Type=Application, and not NoDisplay=true or Hidden=true;
//   - OnlyShowIn / NotShowIn against XDG_CURRENT_DESKTOP;
//   - a TryExec that names a program that is not installed hides it;
//   - helper launchers are not applications to the user: the helper ids below, and terminal emulators' server and client
//     launchers (a TerminalEmulator entry whose Exec runs "--server" or "--daemon", or whose program ends in "client").
namespace ApplicationsLogic
{

struct Entry {
    QString id;          // "org.gnome.Calculator", "kde-foo"
    QString name;        // localized Name, else Name
    QString genericName; // localized GenericName
    QString comment;     // localized Comment
    QString icon;        // Icon= as written: a theme icon name or an absolute path
    QString exec;        // Exec= as written (for Get Info only: Files never runs it by itself)
    QString path;        // the .desktop file
    QStringList categories;
};

struct Environment {
    // applications directories (".../share/applications") in priority order: the user's first.
    QStringList applicationDirs;
    // XDG_CURRENT_DESKTOP split on ':'.
    QStringList currentDesktop;
    // Locale suffixes to try for Name[...], most specific first: "fr_FR", "fr".
    QStringList locales;
    // Ids that are helpers.
    QSet<QString> helperIds;
    // Whether a TryExec program is installed (absolute path: executable file; else looked up on PATH).
    std::function<bool(const QString &)> programExists;
};

// The ids the shell's hidden-entries.sh hides as helpers by default (GRASSFIELD_HELPER_IDS replaces them there).
QStringList defaultHelperIds();

// The environment of this process: XDG_DATA_HOME / XDG_DATA_DIRS, XDG_CURRENT_DESKTOP, the UI locale, the default helper
// ids and the PATH lookup.
Environment processEnvironment();

// Locale suffixes for a locale name such as "fr_FR.UTF-8" or "fr": {"fr_FR", "fr"}.
QStringList localeCandidates(const QString &localeName);

// One desktop entry's text -> an entry, or false when it is not shown (the rules above, except the id-based helper rule).
// `id` and `path` are copied into the entry.
bool parseEntry(const QByteArray &text, const QString &id, const QString &path, const Environment &env, Entry *out);

// Every shown application, sorted by name (case-insensitive, numbers by value), then by id.
QList<Entry> listApplications(const Environment &env);

// The url of the Applications location and of one application in it: grassfield-apps:/ and grassfield-app:/<id>.
QUrl locationUrl();
bool isLocationUrl(const QUrl &url);
QUrl entryUrl(const QString &id);
// The id of an entry url, "" for anything else.
QString entryId(const QUrl &url);

} // namespace ApplicationsLogic
