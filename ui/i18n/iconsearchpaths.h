// The shell's icon search policy (review of 5ee6240, integrator decision): Qt reads, for a theme icon, the index.theme
// and icon-theme.cache of the theme and of every theme it inherits (on the GUI thread, in QIcon::hasThemeIcon) and then
// the icon file it picks; a FIFO, a device or a huge file planted in a user-writable icon directory (~/.icons,
// $XDG_DATA_HOME/icons, a user-writable $XDG_DATA_DIRS entry) froze the shell, and mirroring Qt's index.theme parser to
// check those files first proved endless. So Qt's theme and fallback (pixmaps) search paths keep only directories the
// user can neither write nor replace: the directory and every ancestor of its canonical path belong to root (or, inside
// a user namespace such as a test sandbox, to the overflow uid root maps to), not to this user, and are not writable by
// this user. User-installed icons are shown through ThemeIcons' checked private copies instead (shell/services).
//
// Only this process is affected: no environment variable changes, so applications launched from the shell keep the
// session's own XDG_DATA_HOME / XDG_DATA_DIRS and icon paths, and Quickshell's DesktopEntries still lists user
// applications.
#pragma once

#include <QtCore/QDebug>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QStandardPaths>
#include <QtCore/QStringList>
#include <QtGui/QIcon>

#include <sys/stat.h>
#include <unistd.h>

#include <fstream>
#include <string>

namespace GrassfieldIconPolicy {

// The uid root appears as: 0, or the kernel's overflow uid when this process runs in a user namespace that does not map
// root (bubblewrap, a test sandbox); -1 when there is none.
inline long overflowRoot()
{
    std::ifstream map("/proc/self/uid_map");
    std::string inside, outside, count;
    if (map >> inside >> outside >> count && inside == "0" && outside == "0")
        return -1; // the initial namespace: root is 0
    std::ifstream overflow("/proc/sys/kernel/overflowuid");
    long uid = -1;
    if (overflow >> uid)
        return uid;
    return -1;
}

// `path` (canonical) and each of its ancestors are owned by root, not by this user, and not writable by this user.
inline bool userCannotChange(const QString &path)
{
    const long mappedRoot = overflowRoot();
    QString p = path;
    while (true) {
        struct stat st;
        const QByteArray native = QFile::encodeName(p);
        if (::stat(native.constData(), &st) != 0)
            return false;
        const bool rootOwned = st.st_uid == 0 || (mappedRoot >= 0 && static_cast<long>(st.st_uid) == mappedRoot);
        if (!rootOwned || st.st_uid == ::geteuid() || ::access(native.constData(), W_OK) == 0)
            return false;
        if (p == QStringLiteral("/"))
            return true;
        p = QFileInfo(p).path();
    }
}

// Canonical forms of the existing directories among `candidates` that the user cannot change, in order, once each.
inline QStringList systemOnly(const QStringList &candidates)
{
    QStringList kept;
    for (const QString &candidate : candidates) {
        const QFileInfo info(candidate);
        const QString canonical = info.canonicalFilePath();
        if (canonical.isEmpty() || !QFileInfo(canonical).isDir() || kept.contains(canonical))
            continue;
        if (userCannotChange(canonical))
            kept << canonical;
    }
    return kept;
}

// Sets Qt's icon theme and fallback search paths to the system-only directories of the usual ones (the platform theme's
// $HOME/.icons and every GenericDataLocation "icons"; Quickshell's fallback /usr/share/pixmaps and every
// GenericDataLocation "pixmaps"), plus Qt's own resources. What Qt then uses is logged once: tests read the line.
inline void restrictToSystemDirectories()
{
    QStringList themeCandidates{QDir::homePath() + QStringLiteral("/.icons")};
    themeCandidates << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("icons"), QStandardPaths::LocateDirectory);
    QStringList fallbackCandidates{QStringLiteral("/usr/share/pixmaps")};
    fallbackCandidates << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("pixmaps"), QStandardPaths::LocateDirectory);
    QStringList theme = systemOnly(themeCandidates);
    theme << QStringLiteral(":/icons");
    const QStringList fallback = systemOnly(fallbackCandidates);
    QIcon::setThemeSearchPaths(theme);
    QIcon::setFallbackSearchPaths(fallback);
    // What Qt now uses, read back (tests check this line).
    qInfo().noquote() << "grassfield-icons: theme search paths" << QIcon::themeSearchPaths().join(QLatin1Char(';')) << "fallback"
                      << QIcon::fallbackSearchPaths().join(QLatin1Char(';'));
}

} // namespace GrassfieldIconPolicy
