// Where the catalog comes from (ADR-0037 g "Where"): beside the channel's repository, <base>/<channel>/<arch>/. The channel
// and base come from the primary Server of /etc/pacman.d/grassfield.conf (`Server = <base>/<channel>/$arch`, ADR-0033 a),
// else from the base this build was made with (GRASSFIELD_REPO_BASE of packaging/pacman/repository.conf) and `stable`.
// While the base is the .invalid placeholder, nothing is fetched. Pure: the caller reads the file.
#pragma once

#include <QByteArray>
#include <QString>
#include <QUrl>

#include <optional>

namespace grassfield::store {

struct Channel {
    QString name; // stable or beta
    QUrl base;    // https://host[/path], no trailing slash
};

// The primary (first) Server of grassfield.conf when it has the channel's shape; nothing otherwise (a `custom` Server, a
// missing or unreadable file: the build's own base is used then).
std::optional<Channel> channelFromConf(const QByteArray &grassfieldConf);
// GRASSFIELD_REPO_BASE of the installed repository.conf (/usr/share/grassfield/pacman/repository.conf); "" when absent.
QString buildBase(const QByteArray &repositoryConf);
// True when the build names a signing key (GRASSFIELD_SIGNING_FINGERPRINT non-empty), the condition grassfield-channel-set,
// the helper, the update checker and Settings (SoftwareUpdateLogic.buildReady) use. Without it the catalog could not be
// verified, so the Store asks nothing of the build's host.
bool buildHasKey(const QByteArray &repositoryConf);
// The channel a build follows when none is set up, from the installed VERSION (/usr/share/grassfield/VERSION): `stable` for a
// plain X.Y.Z, `beta` for a -betaN / -rcN version and for a missing, empty or malformed one (ADR-0033 O15b: stable carries
// nothing until a plain version is published, and beta carries every release).
QString releaseChannelOf(const QByteArray &versionText);
// The build's base and the channel (`stable` by default).
Channel defaultChannel(const QString &buildBase, const QString &name = QStringLiteral("stable"));
// The channel of the installed repository.conf: its base when the build names a key (buildHasKey), else no base at all
// (nothing fetchable, nothing requested).
Channel buildChannel(const QByteArray &repositoryConf, const QByteArray &versionText);
// False while the base is a placeholder (a host under .invalid, ADR-0033 g) or not https.
bool fetchable(const Channel &channel);

// <base>/<channel>/<arch>/grassfield-catalog.v1.json, its .sig, and catalog/<sha256>.png.
QUrl catalogUrl(const Channel &channel, const QString &arch = QStringLiteral("x86_64"));
QUrl signatureUrl(const QUrl &file);
QUrl iconUrl(const Channel &channel, const QString &sha256, const QString &arch = QStringLiteral("x86_64"));

// Every request and redirect of the Store: https only; file:// only through dev plumbing (GRASSFIELD_STORE_CATALOG_URL in
// a dev session, ADR-0019).
bool requestAllowed(const QUrl &url, bool devPlumbing);

} // namespace grassfield::store
