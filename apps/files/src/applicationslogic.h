#pragma once

#include <QByteArray>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>

// The Applications location of Files (macOS: the Applications folder in the Finder sidebar): the applications the shell's Apps
// grid lists, by the grid's own behaviour. Qt Core only. The location is virtual and read-only: its items are never files to
// rename, move or delete, and opening one starts the application (FilesApp::launchApplication).
//
// "The grid's behaviour" is three things, each reproduced here and checked against the real ones on the same fixture tree by
// tests/shell/apps_grid_vs_files.sh (Quickshell's DesktopEntries run offscreen, hidden-entries.sh, Model.disambiguate):
//   1. Quickshell 0.3.1's DesktopEntries (what AppsController.qml iterates). Measured, not the desktop entry specification:
//      - applications directories of XDG_DATA_HOME, then XDG_DATA_DIRS; the first one that has an id wins, and an id whose
//        winning file is not listed (Hidden=true, NoDisplay=true, not an application, no Name) is not listed from a later one;
//      - every *.desktop file below them, symlinked folders followed, any depth, never dot files or dot folders; the id is
//        the path below the directory with "/" written "-"; when two files give one id (kde/foo.desktop and kde-foo.desktop)
//        the one that comes last in a case-insensitive name sort of the folder wins;
//      - the file is read as written: no trimming of keys, values or the "[Desktop Entry]" line (a CRLF file, "Type = Application",
//        "  NoDisplay=true" and "Name = x" are therefore not understood), a UTF-8 byte order mark is skipped, only the first
//        [Desktop Entry] group counts, a key given twice takes its last value;
//      - listed: Type=Application exactly, a Name (localized by Name[fr_FR] then Name[fr]; else Name; else the first Name[...]
//        of the file), not NoDisplay=true, not Hidden=true. TryExec is NOT read (the grid lists an entry whose TryExec program is
//        missing; the desktop entry specification says to hide it. Not changed here: the grid is the reference).
//   2. shell/launchpad/hidden-entries.sh, which reads OnlyShowIn, NotShowIn, Categories and Exec by its own lenient rules (a
//      trailing blank and CR are cut, "Key = value" is accepted, the last of a repeated key wins, every [Desktop Entry] group
//      counts) and hides: OnlyShowIn / NotShowIn against XDG_CURRENT_DESKTOP, the helper ids (below), and terminal emulators'
//      server and client launchers (Categories listing TerminalEmulator with a ';' after it, and an Exec whose program ends in
//      "client" or that has "--server" or "--daemon" as an argument).
//   3. Model.disambiguate (shell/launchpad/Model.js): two apps with one Name (case-insensitive) are told apart, "Files (GNOME)";
//      Grassfield's own (id org.grassfield.*) keeps the plain name. The grid compares names with JS String.trim (jsTrim here:
//      a Name that ends in U+FEFF collides with the same name without it, as in the grid).
//
// Known differences from the grid, on purpose and not fixed:
//   - A symbolic link loop inside an applications directory: Quickshell follows it about 28 levels deep and lists a ghost id
//     for each level (866 ids on the review fixture); Files cuts the loop (visited set) and lists each entry once.
//   - Icons: the grid draws them through the shell's ThemeIcons (image-copy.py, out of process); Files uses the icon theme and
//     appicons.h for an absolute Icon= path (PNG, and SVG without any reference to another file; other formats and an SVG
//     with a reference show the generic application icon).
namespace ApplicationsLogic
{

struct Entry {
    QString id;          // "org.gnome.Calculator", "kde-foo"
    QString name;        // localized Name, told apart from an app of the same name (disambiguate)
    QString baseName;    // localized Name as the entry has it
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
};

// The ids the shell's hidden-entries.sh hides as helpers by default (GRASSFIELD_HELPER_IDS replaces them there).
QStringList defaultHelperIds();

// The environment of this process: XDG_DATA_HOME / XDG_DATA_DIRS, XDG_CURRENT_DESKTOP, the UI locale and the default helper
// ids.
Environment processEnvironment();

// Locale suffixes for a locale name such as "fr_FR.UTF-8" or "fr": {"fr_FR", "fr"}.
QStringList localeCandidates(const QString &localeName);

// One desktop entry's text -> an entry, or false when the grid does not list it (the rules above, except the id-based helper
// rule and the names being told apart). `id` and `path` are copied into the entry.
bool parseEntry(const QByteArray &text, const QString &id, const QString &path, const Environment &env, Entry *out);

// Model.disambiguate on a list: `name` is replaced where two entries share a Name; `baseName` keeps the entry's own.
void disambiguate(QList<Entry> &entries);

// Every application the grid lists, sorted by name (case-insensitive, numbers by value), then by id.
QList<Entry> listApplications(const Environment &env);

// An Icon= that is an absolute path is handed to the image provider only when it is what the shell's ThemeIcons accepts
// (shell/services/image-copy.py read_source): at most 4096 characters, no control character, its real path under one of
// `roots` (iconRoots(): the user's home and data folders, the system's, flatpak's, /tmp, removable media; never /proc, /sys or
// /dev), a regular non-empty file of at most `cap` bytes, opened without following a link and without blocking (a FIFO or a
// device planted as an icon froze the GUI thread). Returns the real path, or "" for anything else.
QStringList iconRoots();
QString safeIconFile(const QString &path, const QStringList &roots, qint64 cap = 8 * 1024 * 1024);
// The same checks, then the bytes of the file read from the very descriptor that was checked (no second open of the path).
// Empty for anything refused. Decoding is appicons.h's job.
QByteArray readIconFile(const QString &path, const QStringList &roots, qint64 cap = 8 * 1024 * 1024);

// The url of the Applications location and of one application in it: grassfield-apps:/ and grassfield-app:/<id>.
QUrl locationUrl();
bool isLocationUrl(const QUrl &url);
QUrl entryUrl(const QString &id);
// The id of an entry url, "" for anything else.
QString entryId(const QUrl &url);

} // namespace ApplicationsLogic
