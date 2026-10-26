#pragma once

#include <QString>
#include <QStringList>

// Dev guard of the system sections (Wi-Fi, Bluetooth, Sound, Displays). In a dev session (GRASSFIELD_DEV=1, a nested
// Hyprland on the owner's machine) nothing may change the owner's network, Bluetooth, audio or monitors: only the
// read-only queries below may run. Kept free of QML and QObject so the rule is easy to read and to test.
namespace grassfield::settings {

// The run-mode rule (apps/runmode.h, the same as shell/lib/RunMode.js): GRASSFIELD_DEV "1" and GRASSFIELD_SESSION not "1".
bool devSession();

// Exactly the read-only commands the pages issue (qml/System.js builds the same argument vectors; tst_settingssystem
// checks that every System.QUERY entry is accepted here). Anything else, also a variation of these, is not a query:
//   wpctl      1 fixed (status), the Sound page; Wi-Fi and Bluetooth are read over D-Bus (systembus.h), not by commands
//   pacman -Q (hyprland, quickshell, quickshell-git) and lspci      => 4 more, About pane
//   pacman -Qi (the installed packages' sizes) and du -s -x --block-size=1 -- <1-16 folders of the home>   Storage pane
// Never omarchy-language (Language & Region runs it only in a real session where it is installed: ADR-0030).
// Backend::query and Backend::run both use it.
bool isReadOnlyQuery(const QStringList &argv);

// The du arguments of the Storage pane: exactly -s -x --block-size=1 --, then 1 to 16 clean absolute paths inside the home.
bool isFolderSizeQuery(const QStringList &args);

// A language code of Omarchy's list ("fr", "pt-BR", "zh-CN").
bool isLanguageCode(const QString &code);

// The wallpaper helper (ADR-0016) as the Settings > Wallpaper page runs it. Only the helper at its exact path (installed
// /usr/lib/grassfield/grassfield-wallpaper, or the dev build next to the dev binary), only these argument vectors:
//   <tool> formats
//   <tool> list --max <1..500> -- <folder>
//   <tool> thumb --width <16..1024> --out <cacheDir>/thumbs -- <picture>
// `folder` and `picture` are absolute paths without control characters (at most 4096 bytes); in a dev session they must lie
// under <devRoot>/.dev. `--out` is exactly the thumbnail folder of the wallpaper cache: no other value, no traversal.
// `prepare` is never run by Settings (the shell does). Anything else, also another program called grassfield-wallpaper, is refused.
struct WallpaperContext {
    QString tool;     // the helper's absolute path
    QString cacheDir; // the wallpaper cache root (thumbnails go to <cacheDir>/thumbs)
    QString devRoot;  // the worktree in a dev session, "" otherwise
};
bool isWallpaperQuery(const QStringList &argv, const WallpaperContext &ctx);
// A program that names the helper (its file name), whatever its directory: such a command is judged by isWallpaperQuery only.
bool namesWallpaperTool(const QString &program);

// Programs the pages may run as actions in a real session (wpctl for Sound, xdg-open for links, omarchy-language for Language
// & Region). Anything else is refused: Wi-Fi, Bluetooth and the General pane's system changes are D-Bus calls (Backend::busAct).
bool isActionProgram(const QString &program);

// A whole action command line: an allowed program, for xdg-open exactly one clean https link (xdg-open hands anything else, a
// local file or a .desktop entry, to whatever handler claims it), for omarchy-language exactly one language code.
bool isAllowedAction(const QStringList &argv);

// An allowed action that may wait for a password (omarchy-language: Omarchy's own pkexec prompt). Backend::act runs one per
// tag at a time (busjobs.h InFlight), as busAct does for the polkit actions of ADR-0030 (privilegedAction).
bool asksForPassword(const QStringList &argv);

// How long an allowed action may run: `requested`, or 130 s for Omarchy's language switch, which may wait for its own
// pkexec prompt (a locale to generate) as long as a polkit call of ADR-0030 waits for the user.
int actionTimeoutMs(const QStringList &argv, int requested);

// The one file Login Items may write or remove (Backend::writeAutostart, removeAutostart): <autostartDir>/<plain name>.desktop
// that is not a symbolic link (a write would go through the link to the file it names: a dotfile manager's file, or one outside
// .dev; removing it would break that setup), and in a dev session only when the folder's real location lies under
// <devRoot>/.dev (the isolated XDG_CONFIG_HOME), never the owner's ~/.config/autostart.
bool isAutostartWrite(const QString &path, const QString &autostartDir, const QString &devRoot, bool dev);

// An Icon= that is an absolute path (Login Items, image://icon): a clean path to a regular file (stat follows a link: never a
// FIFO, a device or a directory, which would stall the GUI thread), at most 1 MiB, named as a raster picture (PNG, XPM, JPEG).
// The name alone does not make it one: iconprovider.h decodes it only in the format its extension names, so an SVG (whose
// references QtSvg follows) named .png is refused there. Anything else shows the page's own tile.
bool isIconFile(const QString &path);

// A NetworkManager connection UUID.
bool isUuid(const QString &s);

} // namespace grassfield::settings
