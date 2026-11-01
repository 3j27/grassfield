// The Store's paths and its dev plumbing (ADR-0019 table, ADR-0037 e.8), read only through runmode.h: in a dev session a
// fixture catalog and keyring and fake pacman and AppStream roots; in a real session the system's, and the variables are
// inert.
//   GRASSFIELD_STORE_CATALOG_URL  the catalog's URL (file:// allowed), instead of the channel's
//   GRASSFIELD_STORE_KEYRING      a test keyring folder (grassfield.gpg, grassfield-trusted, grassfield-revoked)
//   GRASSFIELD_STORE_FIXTURE      a folder with bin/pacman and bin/gpg (fakes), gnupg/ (a pacman keyring to copy),
//                                 swcatalog/ (fake AppStream data) and grassfield.conf; the Store reads nothing of the
//                                 system's package manager then
//   GRASSFIELD_STORE_OFFLINE      "1": the Store counts as offline whatever the network says (the offline captures and tests);
//                                 "metered": online on a metered connection (nothing fetched without being asked); "0":
//                                 online, unmetered, whatever the network says (the tests that need the network's answer)
//   GRASSFIELD_STORE_PKEXEC       the program run in pkexec's place for the helper's operations (ADR-0037 b.1): a fake one
//                                 that writes the helper's files under <fixture>/run/grassfield-store
//   GRASSFIELD_STORE_INSTALLER    the program run in place of Omarchy's commands (web apps, b.3; Omarchy's terminal, b.2;
//                                 Open, SR21): it gets the command's name, then its arguments
//   GRASSFIELD_STORE_AUR_URL      the AUR's web service (step 3b2): a file:// folder of answers (aur.h), or another URL
// Without the last two a dev session runs no operation and opens nothing ("dev: not applied", SR30). With a fixture, the
// helper's files, pacman's lock and log, Omarchy's folder (its package lists, the setups' recipes and pinned files),
// grassfield-store-run's folder and pacman-conf are the fixture's too.
#pragma once

#include "runmode.h"
#include "signature.h"

#include <QDir>
#include <QFileInfo>
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

inline bool meteredForced()
{
    return apps::runmode::devValue("STORE_OFFLINE") == QLatin1String("metered");
}

inline bool onlineForced()
{
    return apps::runmode::devValue("STORE_OFFLINE") == QLatin1String("0");
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

// The step-3 paths (ADR-0037 b): the helper and its status folder, pacman's lock and log, Omarchy's package lists and its
// update lock, the system's application entries.
inline const QString helperPath = QStringLiteral("/usr/lib/grassfield/grassfield-store-helper");

inline QString inFixture(const QString &relative, const QString &system)
{
    const QString f = fixture();
    return f.isEmpty() ? system : f + relative;
}

// Quickshell's client, which asks the running shell for a check (ADR-0033 d.7: `qs ipc -p <shell> call update check user`),
// or the fixture's stand-in.
inline QString shellProgram()
{
    return inFixture(QStringLiteral("/bin/qs"), QStringLiteral("/usr/bin/qs"));
}

// Software Update's result (ADR-0033 d.7), which the shell alone writes.
inline QString softwareUpdateFile()
{
    return apps::runmode::stateDir() + QStringLiteral("/software-update.json");
}

inline QString statusDir()
{
    return inFixture(QStringLiteral("/run/grassfield-store"), QStringLiteral("/run/grassfield-store"));
}

inline QString dbLock()
{
    return inFixture(QStringLiteral("/db.lck"), QStringLiteral("/var/lib/pacman/db.lck"));
}

// pacman's sync databases (<DBPath>/sync): when pacman last wrote one, the last completed sync (plancheck.h lastSync).
inline QString syncDir()
{
    return inFixture(QStringLiteral("/sync"), QStringLiteral("/var/lib/pacman/sync"));
}

inline QString pacmanLog()
{
    return inFixture(QStringLiteral("/pacman.log"), QStringLiteral("/var/log/pacman.log"));
}

inline QString pacmanConf()
{
    return inFixture(QStringLiteral("/bin/pacman-conf"), QStringLiteral("/usr/bin/pacman-conf"));
}

inline QString omarchyLists()
{
    return inFixture(QStringLiteral("/omarchy/install"), QStringLiteral("/usr/share/omarchy/install"));
}

inline QString systemApplications()
{
    return inFixture(QStringLiteral("/applications"), QStringLiteral("/usr/share/applications"));
}

// Omarchy's update lock (omarchy-update-lock): ${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock.
inline QString updateLock()
{
    const QString run = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return (run.isEmpty() ? QStringLiteral("/tmp") : run) + QStringLiteral("/omarchy-update.lock");
}

// pkexec: the system's, or in a dev session the fake one ("" without it: no operation).
inline QString pkexec()
{
    return apps::runmode::dev() ? apps::runmode::devValue("STORE_PKEXEC") : QStringLiteral("/usr/bin/pkexec");
}

// The fake program standing for Omarchy's commands in a dev session ("" outside one, or without it).
inline QString installer()
{
    return apps::runmode::devValue("STORE_INSTALLER");
}

// Where one of Omarchy's commands is: ${OMARCHY_PATH:-/usr/share/omarchy}/bin/<name> (ADR-0037 e.5).
inline QString omarchyCommand(const QString &name)
{
    const QString root = qEnvironmentVariable("OMARCHY_PATH");
    return (root.isEmpty() ? QStringLiteral("/usr/share/omarchy") : root) + QStringLiteral("/bin/") + name;
}

// The installed Omarchy a setup runs from, the folder its pins are read against (ADR-0037 b.2, g): the one omarchyCommand
// and grassfield-store-run use, or the fixture's omarchy/.
inline QString omarchyRoot()
{
    const QString root = qEnvironmentVariable("OMARCHY_PATH");
    return inFixture(QStringLiteral("/omarchy"), root.isEmpty() ? QStringLiteral("/usr/share/omarchy") : root);
}

// grassfield-store-run (b.2), started in Omarchy's terminal, and the folder of its files: $XDG_RUNTIME_DIR/grassfield/store
// ("" without XDG_RUNTIME_DIR: no setup runs), or the fixture's run/store.
inline const QString runPath = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");

inline QString runDir()
{
    if (!fixture().isEmpty())
        return fixture() + QStringLiteral("/run/store");
    const QString run = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return run.isEmpty() ? QString() : run + QStringLiteral("/grassfield/store");
}

// flatpak (step 3c): the system's, or the fixture's fake; "" when it is not there (no Flathub: the settings say how to get it).
inline QString flatpak()
{
    const QString path = inFixture(QStringLiteral("/bin/flatpak"), QStringLiteral("/usr/bin/flatpak"));
    return QFileInfo(path).isExecutable() ? path : QString();
}

// The user's Flatpak installation, by flatpak's own rule: $FLATPAK_USER_DIR, else $XDG_DATA_HOME/flatpak; or the fixture's.
inline QString flatpakUserDir()
{
    if (!fixture().isEmpty())
        return fixture() + QStringLiteral("/flatpak");
    const QString dir = qEnvironmentVariable("FLATPAK_USER_DIR");
    if (!dir.isEmpty())
        return dir;
    const QString xdg = qEnvironmentVariable("XDG_DATA_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.local/share") : xdg) + QStringLiteral("/flatpak");
}

// Flathub's AppStream in that installation (S21): appstream.xml.gz and icons/<size>/<app id>.png.
inline QString flathubAppStream(const QString &arch)
{
    return flatpakUserDir() + QStringLiteral("/appstream/flathub/") + arch + QStringLiteral("/active");
}

// Its exported application entries: a session sees them once XDG_DATA_DIRS names this folder, from the login after
// flatpak's own install (S20).
inline QString flatpakExports()
{
    return flatpakUserDir() + QStringLiteral("/exports/share");
}

// Whether this session sees them: XDG_DATA_DIRS names the folder (flatpak's profile.d and environment generator add it at
// login, S20).
inline bool flatpakExportsSeen()
{
    const QString exports = flatpakExports();
    const QStringList dirs = qEnvironmentVariable("XDG_DATA_DIRS").split(QLatin1Char(':'));
    return dirs.contains(exports) || dirs.contains(exports + QLatin1Char('/'));
}

inline const QString gpgv = QStringLiteral("/usr/bin/gpgv");
inline const QString bsdtar = QStringLiteral("/usr/bin/bsdtar");

} // namespace grassfield::store::env
