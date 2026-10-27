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
// The build's base and `stable`.
Channel defaultChannel(const QString &buildBase);
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
