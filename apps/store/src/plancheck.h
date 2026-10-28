// The plan check (ADR-0037 e.4; spec SR15, SR22): what an install or an uninstall from a repository would do, read as the
// user before anything is queued (S10: pacman -S --print and -Rs --print need no root and no lock), and why it cannot run.
// grassfield-store-helper checks again under its lock (b.1), grassfield-store-run for a setup (b.2), and the queue checks
// the locks again before each operation. The parsers are pure; the checks run pacman (childprocess.h) and one HEAD request
// (fetch.h), and a setup's read the installed Omarchy's pinned files, on a worker thread.
#pragma once

#include "aur.h"
#include "removal.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <functional>

namespace grassfield::store {

struct PlannedPackage {
    QString name, version, repo;
    qint64 downloadSize = -1; // bytes
    QString url;              // where pacman downloads it from
};

// pacman -Qu: the packages whose update did not finish, those the user holds with IgnorePkg ("[ignored]") left out (S12).
QStringList unfinishedUpdates(const QByteArray &pacmanQu);
// pacman -S --print --print-format '%n %v %r %s %l': one package per line; a malformed line makes the whole plan empty.
QList<PlannedPackage> parsePlan(const QByteArray &out);
// pacman -Si of several packages: name -> installed size in bytes.
QHash<QString, qint64> installedSizes(const QByteArray &pacmanSi);

enum class Refusal {
    None,
    Busy,       // pacman's db.lck, or Omarchy's update lock held by someone else
    Unfinished, // pacman -Qu lists packages: the last system update did not finish
    Outdated,   // the plan upgrades an installed package, does not resolve, or its first file is gone from the mirror
    Offline,    // an install needs the network
    Dependency, // (uninstall) other installed packages need it
    Protected,  // (uninstall) the plan takes a protected package along
    OmarchyChanged, // (setup, AUR) the installed Omarchy lacks the recipe, or a pinned file differs from the catalog's pin
    Repository, // (AUR) a repository has the package: it is installed from there
    NotOnAur,   // (AUR) the AUR does not know the package, or a dependency is on neither the repositories nor the AUR
    Failed,     // pacman (or the AUR) could not be asked
};

struct InstallPlan {
    Refusal refusal = Refusal::None;
    QList<PlannedPackage> packages; // what pacman would add, the app's own first
    // (AUR) what yay would build from the AUR, the app's own first (repo "aur", the AUR's version), and whether a
    // dependency the AUR gave could not be read (the plan may then miss a package the build pulls in).
    QList<PlannedPackage> built;
    bool incomplete = false;
    qint64 downloadSize = 0;
    qint64 installedSize = 0;
    QStringList unfinished; // Unfinished: pacman -Qu's lines
    QStringList upgrades;   // Outdated: the installed packages the plan would upgrade
    QString detail;         // pacman's own message, for Details
};

struct RemovePlan {
    Refusal refusal = Refusal::None;
    QList<PlannedPackage> packages; // what pacman -Rns would remove (name, version)
    QStringList dependents;         // Dependency: the installed packages that need it
    QString protectedPackage;       // Protected: the first one the plan would take along
    QString detail;
};

struct PlanTools {
    QString pacman;     // the program (a fake one through dev plumbing)
    QString dbLock;     // pacman's <DBPath>/db.lck
    QString updateLock; // Omarchy's update lock (${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock)
    bool devPlumbing = false;
    // The HTTP status of a HEAD request (fetch.h headStatus); unset: the mirror is not asked.
    std::function<int(const QUrl &)> head;
};

// A setup's recipe and the catalog's pins (ADR-0037 g), checked against the installed Omarchy at `root`.
struct SetupCheck {
    QString root;   // ${OMARCHY_PATH:-/usr/share/omarchy}
    QString recipe; // omarchy-install-… or omarchy-remove-…
    QList<std::pair<QString, QString>> pins; // (path in Omarchy's folder, SHA-256)
};

// The first pinned file that is missing or differs from its pin in Omarchy's folder `root` (its path, in pin order), ""
// when every one matches; "(no pins)" for an empty list (nothing says the files are the ones read).
QString omarchyDifference(const QString &root, const QList<std::pair<QString, QString>> &pins);

// Someone holds `path` with flock (Omarchy's update lock): asked by taking it without waiting and letting it go at once.
// A missing file is free.
bool lockHeld(const QString &path);

// `ownOperation`: the Store's queue runs one now (it holds Omarchy's lock itself; the queue checks the locks again before
// this one starts), so the locks are not read.
InstallPlan checkInstall(const QStringList &packages, const PlanTools &tools, bool online, bool ownOperation);
RemovePlan checkRemove(const QStringList &packages, const DenyList &deny, const PlanTools &tools, bool ownOperation);
// A setup (b.2): the recipe and the pins first (OmarchyChanged, the file in `detail`), then its packages as above: what
// pacman would add (the recipe may add more, our catalog's text says what), what -Rns would remove (the recipe's
// omarchy-pkg-drop).
InstallPlan checkSetupInstall(const QStringList &packages, const SetupCheck &setup, const PlanTools &tools, bool online, bool ownOperation);
RemovePlan checkSetupRemove(const QStringList &packages, const SetupCheck &setup, const DenyList &deny, const PlanTools &tools, bool ownOperation);
// An AUR package (b.2, step 3b2): the AUR's command (setup.recipe, omarchy-pkg-aur-add) and the pins first, as a setup's;
// then no repository may have the name (yay would take the repository's), the AUR must know it, and the dependencies
// (depends, makedepends, checkdepends) the system lacks (pacman -T) come from the repositories (pacman -S --print: what
// pacman adds, never an upgrade) or from the AUR, whose own are read in turn: at most 25 packages to build, in 6 rounds.
// `info` asks the AUR (aur.h aurInfo). The repositories' packages are in `packages`, the AUR's in `built`.
InstallPlan checkAurInstall(const QString &name, const SetupCheck &setup, const std::function<AurAnswer(const QStringList &)> &info,
                            const PlanTools &tools, bool online, bool ownOperation);

} // namespace grassfield::store
