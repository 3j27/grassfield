#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QUrl>

// What opening an item from Grassfield Files may do (GF-AUDIT-001 GF-070, SEC-12, DT-10). macOS model (Gatekeeper): a
// program, script or launcher is never run because it was double-clicked; Files has no "Open Anyway": apps start from the
// Dock, Apps or Search, and a program the user trusts runs from a terminal. Files decides this itself, before KIO sees the
// item (OpenUrlJob's setRunExecutables(false) does not document what it does with every .desktop file). Qt Core only:
// unit-tested in tests/unit/files/tst_launchguard.cpp.
namespace LaunchGuard
{

enum class Verdict {
    Open,           // hand it to KIO (folders, documents, remote items, web links)
    RefuseLauncher, // a desktop entry that would start a program (Type=Application, Service, a link to a file, unknown)
    RefuseProgram,  // an executable program or script, or a Windows program (its handler, Wine, runs it)
};

// What inspect() learned about a local item.
struct Facts {
    bool local = false;        // a file: URL
    bool regularFile = false;  // a regular file (symlinks followed)
    bool executable = false;   // the user may execute it (symlinks followed)
    QString fileName;          // the item's own name (a link's name, not its target's)
    QString mimeType;          // QMimeDatabase::mimeTypeForFile (name, then content)
    QStringList mimeAncestors; // every ancestor of mimeType
    bool shebang = false;      // starts with "#!"
    bool elf = false;          // starts with the ELF magic
    bool desktopEntry = false; // named *.desktop / *.kdelnk, or of type application/x-desktop
    QString desktopType;       // [Desktop Entry] Type= ("" when absent or unreadable)
    QString desktopUrl;        // [Desktop Entry] URL= (Type=Link)
};

// Pure decision on the facts. Fail closed: a desktop entry that cannot be read or has no Type is a launcher.
Verdict verdict(const Facts &facts);

// Reads what verdict() needs (bounded: the first 64 KiB of a desktop entry, the first 4 bytes of an executable file).
Facts inspect(const QUrl &url);

// The Type and URL keys of the [Desktop Entry] group (KDE's legacy [KDE Desktop Entry] too); localized and other
// groups are ignored. Missing keys leave the outputs empty.
void parseDesktopEntry(const QByteArray &text, QString *type, QString *url);

} // namespace LaunchGuard
