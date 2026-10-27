// The catalog the Store uses (ADR-0037 c "Cache", g): a copy is used only after its signature, its rules and its serial
// pass, every time, whether it was just fetched or read from the cache (the cache is the user's to change).
//   cache (regenerable): <cacheDir>/<channel>/grassfield-catalog.v1.json, .sig, etag; <cacheDir>/icons/<sha256>.png
//   state: <stateDir>/store.json, version 1: {"catalog": {"<channel>": {"serial": N, "fetchedAt": "<UTC>"}}} (other keys
//          kept; step 3 adds the operation in flight)
// A serial lower than the accepted one is a replayed old catalog: refused, the accepted one stays.
#pragma once

#include "catalog.h"

#include <QByteArray>
#include <QDateTime>
#include <QString>
#include <QStringList>

#include <optional>

namespace grassfield::store {

class CatalogStore
{
public:
    // gpgv: the program; keyringDir: grassfield-keyring's private folder (signature.h).
    CatalogStore(const QString &cacheDir, const QString &stateFile, const QString &gpgv, const QString &keyringDir);

    enum class Outcome { Accepted, NoTrustedKey, BadSignature, Refused, Replayed, Missing };
    struct Result {
        Outcome outcome = Outcome::Missing;
        QString reason;
        std::optional<Catalog> catalog;
        QStringList dropped;
    };

    // A copy just fetched: checked, then cached with its ETag and its serial recorded.
    Result accept(const QString &channel, const QByteArray &json, const QByteArray &sig, const QByteArray &etag);
    // The cached copy, checked again.
    Result loadCached(const QString &channel) const;

    QByteArray cachedEtag(const QString &channel) const;
    QDateTime fetchedAt(const QString &channel) const;
    qint64 acceptedSerial(const QString &channel) const;
    // When a 304 confirms the cached copy: only its fetch time moves.
    void touch(const QString &channel);

    // An icon of the catalog: stored only if its bytes have the SHA-256 and the size the signed file lists. The folder is
    // kept under 32 MiB, least recently used first.
    bool storeIcon(const CatalogIcon &icon, const QByteArray &data);
    QString iconPath(const CatalogIcon &icon) const; // "" when not cached (or no longer matching)

private:
    Result check(const QString &channel, const QByteArray &json, const QByteArray &sig) const;
    void recordAccepted(const QString &channel, qint64 serial);
    QString channelDir(const QString &channel) const;

    QString m_cacheDir;
    QString m_stateFile;
    QString m_gpgv;
    QString m_keyringDir;
};

} // namespace grassfield::store
