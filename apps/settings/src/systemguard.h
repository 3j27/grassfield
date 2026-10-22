#pragma once

#include <QString>
#include <QStringList>

// Dev guard of the system sections (Wi-Fi, Bluetooth, Sound, Displays). In a dev session (GRASSFIELD_DEV=1, a nested
// Hyprland on the owner's machine) nothing may change the owner's network, Bluetooth, audio or monitors: only the
// read-only queries below may run. Kept free of QML and QObject so the rule is easy to read and to test.
namespace grassfield::settings {

// GRASSFIELD_DEV === "1", like Quickshell.env("GRASSFIELD_DEV") in the shell services.
bool devSession();

// Exactly the read-only commands the pages issue (qml/System.js builds the same argument vectors; tst_settingssystem
// checks that every System.QUERY entry is accepted here). Anything else, also a variation of these, is not a query:
//   nmcli      4 fixed (radio, wifi list, connection list, device list) + 1 per saved profile (its SSID, by UUID)
//   bluetoothctl 3 fixed (show, devices Paired, devices Connected)
//   wpctl      1 fixed (status)                                     => 8 fixed + 1 parameterised, system sections
//   pacman -Q (hyprland, quickshell, quickshell-git) and lspci      => 4 more, About pane
// Backend::query and Backend::run both use it.
bool isReadOnlyQuery(const QStringList &argv);

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

// Programs the pages may run as actions in a real session. Anything else is refused.
bool isActionProgram(const QString &program);

// A whole action command line: an allowed program, and for xdg-open exactly one clean https link (xdg-open hands
// anything else, a local file or a .desktop entry, to whatever handler claims it).
bool isAllowedAction(const QStringList &argv);

// A NetworkManager connection UUID.
bool isUuid(const QString &s);

} // namespace grassfield::settings
