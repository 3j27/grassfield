// What the Store may uninstall (ADR-0037 a "What the Store removes", b.1; spec SR22; S16): the rule
// grassfield-store-helper's remove applies, read here as the user to say beforehand why "Uninstall…" is not offered. The
// deny list is the helper's, held to the same answers by tests/fixtures/store/removal-vectors.json (tst_removal.cpp here,
// tests/integration/store_helper.sh for the helper). Pure: pacman's lists are read elsewhere.
#pragma once

#include <QByteArray>
#include <QSet>
#include <QString>
#include <QStringList>

namespace grassfield::store {

// Why a package is never removed by the Store: none, or the reason its product page gives.
enum class Protection { None, System, Omarchy, Grassfield };

struct DenyList {
    QSet<QString> omarchy; // Omarchy's two package lists (omarchy-base.packages, omarchy-other.packages)
    QSet<QString> holdPkg; // pacman's HoldPkg
    bool omarchyRead() const { return !omarchy.isEmpty(); }
};

// The names of an Omarchy package list: comments (#…) and blank lines left out, one or more names per line.
QSet<QString> parsePackageList(const QByteArray &text);

// Grassfield's names first, then Omarchy's (its prefix, yay, its lists), then the system's (the fixed list, the kernels,
// systemd, the boot manager, pacman, firmware, HoldPkg). A name of a list that is also the system's says "system".
Protection protection(const QString &name, const DenyList &deny);

// "Uninstall…" for an installed app (SR22), or why not. The facts are the user's reading of pacman's database.
enum class Removal {
    Removable,
    NotInstalled,
    PartOfSystem,      // Protection::System
    PartOfOmarchy,     // Protection::Omarchy
    PartOfGrassfield,  // Protection::Grassfield
    Dependency,        // installed, but not explicitly: another app pulled it in
    NotAnApp,          // owns no application entry (a command-line tool)
    NotFromRepository, // no repository has it: removed through Omarchy's terminal (b.2, step 3b)
    ListsMissing,      // Omarchy's lists cannot be read: nothing is removed
};

struct RemovalFacts {
    bool installed = false;
    bool explicitlyInstalled = false;
    bool inRepository = false;
    bool ownsEntry = false;
};

Removal removal(const QString &package, const RemovalFacts &facts, const DenyList &deny);

// The removal plan (`pacman -Rs --print --print-format '%n %v'`, what -Rns removes) checked against the deny list: the
// first protected package it would take along, "" when none.
QString protectedInPlan(const QStringList &plan, const DenyList &deny);

// "removing X breaks dependency 'X' required by Y" (pacman -Rs --print, refused; stdout and stderr together): the packages
// that need it, sorted.
QStringList dependentsFromError(const QByteArray &pacmanOutput);

} // namespace grassfield::store
