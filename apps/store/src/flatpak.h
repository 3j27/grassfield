// Flathub in the user's own Flatpak installation (ADR-0037 a, b.3, c; step 3c part 2, SD25 to SD27): what the Store reads
// of `flatpak` and asks it, as the user, without root or a terminal. Flathub is added to that installation when its switch
// is turned on (`remote-add --user --if-not-exists`, S21); its AppStream and icons are flatpak's own copy there, refreshed
// with `update --user --appstream`; the apps installed are `list --user --app`. Before an install the sheet shows flatpak's
// own plan, read on a pseudo-terminal of the Store's (flatpak asks its question only on one) and answered no (S23), and
// what the app's metadata grants it (`remote-info --show-metadata`, S22). The parsers are pure; the commands run as the
// Store's children (childprocess.h, and the plan's own pseudo-terminal) with LC_ALL=C.
#pragma once

#include "plancheck.h"

#include <QByteArray>
#include <QList>
#include <QProcessEnvironment>
#include <QSet>
#include <QString>
#include <QStringList>

#include <optional>

namespace grassfield::store {

inline const QString kFlathubRemote = QStringLiteral("flathub");
inline const QString kFlathubRepoFile = QStringLiteral("https://dl.flathub.org/repo/flathub.flatpakrepo");

// An app's ref as Flathub's AppStream bundle names it: app/<id>/<arch>/<branch>, each part checked (catalog.h isFlatpakId).
bool isFlatpakAppRef(const QString &ref);
// The app id of a ref ("" when it is not one).
QString flatpakRefId(const QString &ref);
// flatpak's own name for this machine's architecture: x86_64, aarch64, i386 or arm ("" for another).
QString flatpakArch();

// `flatpak list --user --app --columns=application`: the app ids, each checked (a line that is not one is left out).
QSet<QString> parseFlatpakList(const QByteArray &out);
// `flatpak remotes --user --columns=name`: whether Flathub is there.
bool hasFlathubRemote(const QByteArray &out);

// A pseudo-terminal's output as lines of text: escape sequences dropped, carriage returns as line ends.
QStringList terminalLines(const QByteArray &output);

// A size as flatpak writes it ("418.8 MB", "68.6 kB", "1.0 GB", "512 bytes", its space a no-break space or, in the C locale,
// "?"): bytes (SI units, as GLib's g_format_size), -1 when it is not one.
qint64 parseFlatpakSize(const QString &text);

// One row of flatpak's own table: "  1.     org.gnome.Platform      50       i   flathub   < 418.8 MB".
struct FlatpakRow {
    QString id, branch;
    QString op; // i (install), u (update), r (remove)
    qint64 download = -1; // the most it downloads ("<"), -1 when the row has none
};
// The table before "Proceed with these changes …?" (S23): its rows in order; empty when there is no table.
QList<FlatpakRow> parseFlatpakPlan(const QStringList &lines);

// Which question flatpak asks at the end of `lines` (what it printed since the last answer).
enum class FlatpakPrompt {
    None,
    RequiredRuntime, // "Required runtime for … found in remote flathub" then "Do you want to install it? [Y/n]:": yes
    Proceed,         // "Proceed with these changes to the user installation? [Y/n]:": the table is complete; no
    Other,           // any other question (another remote, a choice of refs): no, and the plan is not used
};
FlatpakPrompt flatpakPrompt(const QStringList &lines);

// What an app's metadata (`remote-info --show-metadata`) lets it reach beyond its own window (Wayland, or X11 only as
// a fallback where Wayland is missing; the graphics processor drawing it) and its own folder in ~/.var/app (SR11, SD25):
// every grant named, never one left out. Keys, in this order, each once: network, allFiles (host, host-os, host-etc),
// home, folders (any other path), devices (all), input, usb (devices=usb, or [USB Devices] it may list), kvm, audio
// (the sound server: speakers and microphone), x11, sharedMemory (shared=ipc, devices=shm), printers (cups), ssh
// (ssh-auth), gpg (gpg-agent), smartCards (pcsc), bus (the whole session bus), systemBus, bluetooth, canbus, devel,
// multiarch, outside (it may start programs outside its sandbox: the whole session bus, or org.freedesktop.Flatpak,
// org.freedesktop.systemd1 or the permission store, by name or a wildcard). Then "sessionService:<name>" and
// "systemService:<name>" for each bus name it may talk to or own, sorted (on the session bus, not the harmless ones:
// notifications, tray, menus, screen saver, accessibility, file manager, the portals, media-player names and its own),
// and "other:<text>" for each grant the Store does not know, as flatpak writes it. At most 30 lines: the last is then
// "more:<count>". nullopt when it is not an app's metadata (no [Application] name): unknown, never "nothing".
std::optional<QStringList> flatpakAccess(const QByteArray &metadata);

// What `remote-info` (before an install) or `info --user` (after) says of an app, for the Information list (SR11).
struct FlatpakFacts {
    QString version, license;
    qint64 download = -1;  // remote-info's Download Size
    qint64 installed = -1; // remote-info's Installed Size, info's Installed
    std::optional<QStringList> access; // flatpakAccess of its metadata; nullopt when it could not be read
};
// Their "Key: value" lines (version, licence, sizes; access is not in them).
FlatpakFacts parseFlatpakInfo(const QByteArray &out);

// The refs flatpak names on its "Installing <ref>" lines (or "Uninstalling"), each once: an operation's progress.
int flatpakSteps(const QByteArray &output, bool install);

struct FlatpakTools {
    QString flatpak = QStringLiteral("/usr/bin/flatpak");
    QProcessEnvironment env; // the user's HOME, XDG folders and proxy: flatpak's user installation is under them
    int planMs = 60 * 1000;  // the plan's pseudo-terminal, at most
};
// The environment flatpak runs with: LC_ALL=C and PATH as every child, the user's own HOME, XDG_* folders, session bus
// and proxy settings (its downloads honour them).
QProcessEnvironment flatpakEnvironment();

// The ids `flatpak list --user --app` gives; nullopt when flatpak could not be asked.
std::optional<QSet<QString>> listFlatpakApps(const FlatpakTools &tools);
// Whether the user's installation has Flathub (`remotes --user`).
bool flathubAdded(const FlatpakTools &tools);
// Adds Flathub to the user's installation (S21: a second, no root) and fetches its AppStream; "" or why not.
QString addFlathub(const FlatpakTools &tools);
// Flathub's AppStream in the user's installation fetched again (S21: 10 s the first time, about 1 s after); "" or why not.
QString refreshFlathubAppStream(const FlatpakTools &tools);
// Whether the user's installation has the app (`list --user --app`).
bool flatpakInstalled(const FlatpakTools &tools, const QString &appId);
// An app's facts: of Flathub's ref before an install (`remote-info --user flathub <ref>`, online), of the installed app id
// after (`info --user <id>`), each with its metadata (--show-metadata); nullopt when flatpak could not answer.
std::optional<FlatpakFacts> flatpakFacts(const FlatpakTools &tools, const QString &target, bool installed);

// A Flatpak's install plan (SD25): what its metadata grants it (`access`), then flatpak's own plan on a pseudo-terminal,
// answered yes for the runtime it requires and no to proceed, so nothing is installed: the refs it would add (packages:
// name the ref's id, version its branch, repo "flathub", downloadSize the most each downloads) and their total
// (downloadSize; installedSize unknown, -1). Offline when not online; Failed with flatpak's words in `detail` when the app
// is not on Flathub, the table cannot be read, or flatpak asks anything else.
InstallPlan checkFlatpakInstall(const QString &ref, const FlatpakTools &tools, bool online);

} // namespace grassfield::store
