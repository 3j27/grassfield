// Where Arch's AppStream comes from (ADR-0037 c, owner ST5, SD4): the installed archlinux-appstream-data
// (/usr/share/swcatalog) when there is one; otherwise the same package file fetched from pacman's own mirror
// (`pacman -Sp archlinux-appstream-data`, as the user), checked by its own signature as pacman checks it (pacman's keyring
// and rule, one fully trusted and enabled signer: verifyPacmanSignature, S17, S19) and only then unpacked into the cache
// (a package of at most 64 MiB). The copy is replaced when pacman's database names another version; one version is kept.
// One refresh runs at a time (the Store's own): a .work-* folder left by an interrupted one is removed at the start.
//   <cacheDir>/appstream/<version>/usr/share/swcatalog/{xml,icons}/…, <cacheDir>/appstream/current (the version in use)
#pragma once

#include "appstream.h"
#include "signature.h"

#include <QList>
#include <QString>

#include <functional>

namespace grassfield::store {

struct AppStreamData {
    enum class Origin { None, Installed, Fetched };
    Origin origin = Origin::None;
    QString root; // the swcatalog folder: xml/ and icons/<origin>/<size>/<file>
    QString version; // Fetched only
    QList<AppStreamComponent> components;
};

// Reads every <root>/xml/*.xml.gz (each at most 64 MiB once decompressed).
AppStreamData readAppStream(const QString &swcatalogRoot, AppStreamData::Origin origin);

// Flathub's AppStream in the user's Flatpak installation (step 3c; S21): <activeDir>/appstream.xml.gz, flatpak's own copy
// (it checked it against Flathub's key when it fetched it), at most 128 MiB once decompressed; its icons are
// <activeDir>/icons/<width>x<height>/<file>. Origin::Installed when the file is there.
AppStreamData readFlathubAppStream(const QString &activeDir);

// The package file's URL and version from `pacman -Sp archlinux-appstream-data` (its last line), or empty.
struct PackageFile {
    QString url;
    QString version; // "20260821-1" from archlinux-appstream-data-20260821-1-any.pkg.tar.zst
};
PackageFile packageFileFromPrint(const QByteArray &pacmanSp);

struct AppStreamTools {
    QString pacman = QStringLiteral("/usr/bin/pacman");
    QString gpg = QStringLiteral("/usr/bin/gpg");
    QString pacmanGnupg = kPacmanGnupg;
    QString bsdtar = QStringLiteral("/usr/bin/bsdtar");
    // Downloads url to a file (fetch.h's rules, the caps given); false on any failure.
    std::function<bool(const QString &url, const QString &file, qint64 maxBytes, int timeoutMs)> download;
};

// The cached copy (Origin::Fetched), or Origin::None when there is none.
AppStreamData readFetched(const QString &cacheDir);

// Why a refresh did not bring the copy pacman's database names, each with its own words in the window (the integrator's note
// on PR #36: a package file the mirror no longer has is not a signature that fails).
enum class RefreshProblem {
    None,
    NoPackageFile,     // pacman names no archlinux-appstream-data file (no sync database, pacman failing)
    Download,          // the package file could not be downloaded: most often a package database older than the mirror (404)
    SignatureDownload, // its .sig could not be downloaded
    Unverified,        // the signature does not pass pacman's rule
    Unpack,            // bsdtar could not unpack it, or it holds no usr/share/swcatalog/xml
    Cache,             // the cache folder cannot be written
};

// Makes the cached copy match pacman's database: nothing when it already does; otherwise downloads, verifies, unpacks,
// switches `current`, removes the old version. A problem leaves the previous copy as it was; `detail` says more, for logs.
RefreshProblem refreshFetched(const QString &cacheDir, const AppStreamTools &tools, QString *detail);

} // namespace grassfield::store
