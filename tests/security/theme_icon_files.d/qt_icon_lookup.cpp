// Qt's own icon lookup with the theme search paths a real session gets (QGenericUnixTheme: $HOME/.icons, every
// GenericDataLocation "icons" directory, :/icons; Quickshell's fallback paths: /usr/share/pixmaps and every
// GenericDataLocation "pixmaps" directory), for tests/security/theme_icon_files.sh. Offscreen Quickshell only searches
// :/icons, so the hostile theme-directory cases need this. Usage: qt_icon_lookup [--policy] <theme> <name>...: with
// --policy, the shell's icon search policy (ui/i18n/iconsearchpaths.h, the very function grassfield-shell runs) is then
// applied over those paths. For each name: QIcon::hasThemeIcon (the GUI-thread call) then a 48 px pixmap (what the
// image loader reads). Progress is flushed before each step, so a stall shows where it happened; "done" at the end.
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QPixmap>
#include <QStandardPaths>
#include <cstdio>
#include <cstring>

#include "iconsearchpaths.h"

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    int first = 1;
    const bool policy = argc > 1 && std::strcmp(argv[1], "--policy") == 0;
    if (policy)
        ++first;
    if (argc <= first)
        return 2;
    QStringList paths;
    const QFileInfo home(QDir::homePath() + QStringLiteral("/.icons"));
    if (home.isDir())
        paths << home.absoluteFilePath();
    paths << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("icons"), QStandardPaths::LocateDirectory);
    paths << QStringLiteral(":/icons");
    QIcon::setThemeSearchPaths(paths);
    QStringList fallback{QStringLiteral("/usr/share/pixmaps")};
    fallback << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("pixmaps"), QStandardPaths::LocateDirectory);
    QIcon::setFallbackSearchPaths(fallback);
    if (policy)
        GrassfieldIconPolicy::restrictToSystemDirectories();
    QIcon::setThemeName(QString::fromLocal8Bit(argv[first]));
    for (int i = first + 1; i < argc; ++i) {
        const QString name = QString::fromLocal8Bit(argv[i]);
        std::printf("has %s ...\n", argv[i]);
        std::fflush(stdout);
        const bool has = QIcon::hasThemeIcon(name);
        std::printf("has %s=%d\npixmap %s ...\n", argv[i], has ? 1 : 0, argv[i]);
        std::fflush(stdout);
        const QPixmap pixmap = QIcon::fromTheme(name).pixmap(48);
        std::printf("pixmap %s null=%d\n", argv[i], pixmap.isNull() ? 1 : 0);
        std::fflush(stdout);
    }
    std::printf("done\n");
    return 0;
}
