// pacman's databases as the user reads them (ADR-0037 c (3), S10): no root, no lock. `pacman -Sl` lists the packages of the
// repositories the Store offers ([core], [extra], [multilib], [omarchy]; [grassfield] and any other are left out),
// `pacman -Qqe` the explicitly installed ones, `pacman -Qqm` those no repository has, `pacman -Si` one package's facts
// for its product page. The parsers are pure (LC_ALL=C output); Pacman runs the queries (childprocess.h).
#pragma once

#include <QByteArray>
#include <QDate>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>

#include <optional>

namespace grassfield::store {

struct SyncPackage {
    QString repo;
    QString name;
    QString version;
    bool installed = false;
};

struct PackageInfo {
    QString repo, name, version, description, url;
    QStringList licenses;
    qint64 downloadSize = -1; // bytes
    qint64 installedSize = -1;
    QDate buildDate; // invalid when pacman gives none that parses
};

bool isStoreRepository(const QString &repo);
QList<SyncPackage> parseSyncList(const QByteArray &pacmanSl);
QSet<QString> parseNameList(const QByteArray &out);
std::optional<PackageInfo> parsePackageInfo(const QByteArray &pacmanSi);
// "21.56 MiB" → bytes; -1 when it is not a size.
qint64 parseSize(const QString &text);
// pacman's "Build Date" in the C locale ("Thu Oct 15 08:27:03 2026") → its day; invalid when it does not parse.
QDate parseBuildDate(const QString &text);

class Pacman
{
public:
    explicit Pacman(const QString &program = QStringLiteral("/usr/bin/pacman"));
    QList<SyncPackage> syncList() const;
    QSet<QString> explicitlyInstalled() const;
    QSet<QString> foreign() const;
    std::optional<PackageInfo> info(const QString &package) const;

private:
    QString m_program;
};

} // namespace grassfield::store
