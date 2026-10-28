// The AUR's web service (ADR-0037 c, ST7; spec SR7, SR11, SR23), asked only while the AUR source is on: RPC v5 `info` for an
// AUR page and for the names of the packages no repository has, `search` by name after Return, and a package base's
// PKGBUILD on request ("View Build Script"). Its answers are third-party data (e.6): bounded (512 KiB), parsed as RPC v5 or
// refused whole, every name checked as a package name and every text made plain and cut; nothing of them is ever run or
// shown as rich text. Answers are cached for an hour (4 MiB in all, the oldest dropped first). The blocking calls run on a
// worker thread (fetch.h). Through dev plumbing (GRASSFIELD_STORE_AUR_URL, a file:// folder) the answers are files:
// info.json and search.json (multiinfo and search answers the client filters by the names or the term asked) and
// pkgbuild/<base>.
#pragma once

#include <QByteArray>
#include <QDateTime>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <optional>

namespace grassfield::store {

struct AurPackage {
    QString name, version, base; // Name, Version, PackageBase
    QString description;         // plain, at most 400 characters
    QString maintainer;          // "" when orphaned (Maintainer null)
    bool orphaned = false;
    int votes = 0;
    double popularity = 0;
    QDateTime outOfDate;      // invalid: not flagged
    QDateTime lastModified;
    QDateTime firstSubmitted;
    QStringList licenses;     // plain, at most 8 of 64 characters
    QString url;              // the upstream's homepage, https only ("" otherwise)
    QStringList keywords;
    // The dependencies as the AUR writes them (a name, an operator and a version: "qt6-base>=6.8"), each checked (dependency).
    QStringList depends, makeDepends, checkDepends, optDepends;
    // A dependency the AUR gave that is not one the Store reads: the plan built from this answer is not complete.
    bool dependenciesUnread = false;
};

struct AurAnswer {
    bool ok = false; // the answer parsed as RPC v5 of the type asked
    QList<AurPackage> packages;
    QString error; // why not ok: unavailable (no answer), malformed, or the AUR's own error
};

// An RPC v5 answer of type "multiinfo" (info) or "search": anything else, or a malformed one, is not ok; a result whose Name,
// Version or PackageBase is not one the Store accepts is dropped (the rest are kept).
AurAnswer parseAurAnswer(const QByteArray &json, const QString &expectedType);

// A dependency the Store reads: a package name, then optionally an operator (<, <=, =, >=, >) and a version. Its name, or ""
// when it is not one (an optional dependency's ": why" is cut first).
QString dependencyName(const QString &dependency);

// A term the AUR is searched for: 2 to 64 characters, no control or format character, no "/" (it goes in the path).
bool isAurSearchTerm(const QString &term);

// The service: https://aur.archlinux.org, or the dev plumbing's folder.
struct AurConfig {
    QUrl base;
    bool devPlumbing = false; // base is a file:// folder (dev plumbing, ADR-0019)
    QString cacheDir;         // <Store cache>/aur ("" : no cache)
    int timeoutMs = 15000;
};

AurConfig aurConfig(const QString &storeCacheDir);

QUrl aurInfoUrl(const QUrl &base, const QStringList &names);
QUrl aurSearchUrl(const QUrl &base, const QString &term);
QUrl aurPkgbuildUrl(const QUrl &base, const QString &packageBase);

// info for `names` (package names only; at most 150 in all): each one cached for an hour, the others asked in requests of at
// most 50 names. The packages the AUR knows, in the order asked; ok when every request was answered.
AurAnswer aurInfo(const AurConfig &config, const QStringList &names);
// search by name: at most 50 results, the most voted first; cached for an hour.
AurAnswer aurSearch(const AurConfig &config, const QString &term);
// The PKGBUILD of `packageBase` as plain text (512 KiB at most, line feeds and tabs kept, other control and format
// characters removed); nullopt when it could not be had.
std::optional<QString> aurPkgbuild(const AurConfig &config, const QString &packageBase);

} // namespace grassfield::store
