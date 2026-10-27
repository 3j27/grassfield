// The Store's paths and its dev plumbing (ADR-0019 table, ADR-0037 e.8), read only through runmode.h: in a dev session a
// fixture catalog and keyring and fake pacman and AppStream roots; in a real session the system's, and the variables are
// inert.
//   GRASSFIELD_STORE_CATALOG_URL  the catalog's URL (file:// allowed), instead of the channel's
//   GRASSFIELD_STORE_KEYRING      a test keyring folder (grassfield.gpg, grassfield-trusted, grassfield-revoked)
//   GRASSFIELD_STORE_FIXTURE      a folder with bin/pacman and bin/gpg (fakes), gnupg/ (a pacman keyring to copy),
//                                 swcatalog/ (fake AppStream data) and grassfield.conf; the Store reads nothing of the
//                                 system's package manager then
//   GRASSFIELD_STORE_OFFLINE      "1": the Store counts as offline whatever the network says (the offline captures and tests)
// GRASSFIELD_STORE_INSTALLER and GRASSFIELD_STORE_PKEXEC (the fake programs of the queue) come with step 3.
#pragma once

#include "runmode.h"
#include "signature.h"

#include <QDir>
#include <QString>
#include <QUrl>

namespace grassfield::store::env {

inline QString fixture()
{
    return apps::runmode::devValue("STORE_FIXTURE");
}

inline bool offlineForced()
{
    return apps::runmode::devValue("STORE_OFFLINE") == QLatin1String("1");
}

inline QString cacheDir()
{
    const QString xdg = qEnvironmentVariable("XDG_CACHE_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.cache") : xdg) + QStringLiteral("/grassfield/store");
}

inline QString stateFile()
{
    return apps::runmode::stateDir() + QStringLiteral("/store.json");
}

inline QString keyringDir()
{
    const QString dev = apps::runmode::devValue("STORE_KEYRING");
    return dev.isEmpty() ? kKeyringDir : dev;
}

// The catalog URL dev plumbing gives ("" outside dev, or when unset).
inline QUrl catalogUrlOverride()
{
    const QString dev = apps::runmode::devValue("STORE_CATALOG_URL");
    return dev.isEmpty() ? QUrl() : QUrl(dev);
}

inline QString grassfieldConf()
{
    const QString f = fixture();
    return f.isEmpty() ? QStringLiteral("/etc/pacman.d/grassfield.conf") : f + QStringLiteral("/grassfield.conf");
}

inline QString pacman()
{
    const QString f = fixture();
    return f.isEmpty() ? QStringLiteral("/usr/bin/pacman") : f + QStringLiteral("/bin/pacman");
}

// gpg and the pacman keyring it reads a copy of, for Arch's AppStream package (verifyPacmanSignature).
inline QString gpg()
{
    const QString f = fixture();
    return f.isEmpty() ? QStringLiteral("/usr/bin/gpg") : f + QStringLiteral("/bin/gpg");
}

inline QString pacmanGnupg()
{
    const QString f = fixture();
    return f.isEmpty() ? kPacmanGnupg : f + QStringLiteral("/gnupg");
}

inline QString swcatalogRoot()
{
    const QString f = fixture();
    return f.isEmpty() ? QStringLiteral("/usr/share/swcatalog") : f + QStringLiteral("/swcatalog");
}

inline const QString gpgv = QStringLiteral("/usr/bin/gpgv");
inline const QString bsdtar = QStringLiteral("/usr/bin/bsdtar");

} // namespace grassfield::store::env
