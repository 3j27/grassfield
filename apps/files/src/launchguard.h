#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QUrl>

// What opening an item from Grassfield Files may do (GF-AUDIT-001 GF-070, SEC-12, DT-10). macOS model (Gatekeeper): a
// program, script or launcher is never run because it was double-clicked; Files has no "Open Anyway": apps start from the
// Dock, Apps or Search, and a program the user trusts runs from a terminal. Files decides this itself, before KIO sees the
// item, and never hands KIO a desktop entry (KIO runs a Link's downloaded target with the handler the server's type
// selects, or X-KDE-LastOpenedWith). Qt Core only: unit-tested in tests/unit/files/tst_launchguard.cpp.
namespace LaunchGuard
{

enum class Verdict {
    Open,                 // hand it to KIO (folders, documents, remote items)
    OpenWebLinkInBrowser, // a desktop entry that is only a web link: its http(s) address goes to the default web browser
    RefuseLauncher,       // any other desktop entry (Type=Application, Service, Link to a file, unknown, ambiguous)
    RefuseProgram,        // an executable program or script, or a type whose handler runs it (Windows, Java, AppImage)
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
    bool desktopEntry = false; // named *.desktop / *.kdelnk / .directory, or of type application/x-desktop
    QString desktopType;       // [Desktop Entry] Type= ("" when absent or unreadable)
    QString desktopUrl;        // [Desktop Entry] URL= (Type=Link)
    bool desktopAmbiguous = false; // a key given twice, URL with URL[$e], or longer than what was read
};

struct DesktopKeys {
    QString type;
    QString url;
    bool ambiguous = false; // Type or URL given more than once (KConfig keeps the last one): refuse
};

// Pure decision on the facts. Fail closed: a desktop entry that cannot be read, has no Type or is ambiguous is refused.
Verdict verdict(const Facts &facts);

// The address of a desktop entry that is only a web link (Type=Link, one http(s) URL with a host), else an invalid URL.
QUrl webLink(const Facts &facts);

// Reads what verdict() needs (bounded: the first 64 KiB of a desktop entry, the first 4 bytes of an executable file).
Facts inspect(const QUrl &url);

// The Type and URL keys of the [Desktop Entry] group (KDE's legacy [KDE Desktop Entry] too); other groups are ignored.
DesktopKeys parseDesktopEntry(const QByteArray &text);

} // namespace LaunchGuard
