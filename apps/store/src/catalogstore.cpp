#include "catalogstore.h"

#include "signature.h"
#include "statefile.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QTemporaryDir>

#include <algorithm>

namespace grassfield::store {

namespace {

constexpr qint64 kIconCacheBytes = 32 * 1024 * 1024;
const QString kCatalogFile = QStringLiteral("grassfield-catalog.v1.json");

bool validChannel(const QString &channel)
{
    return channel == QLatin1String("stable") || channel == QLatin1String("beta");
}

QByteArray readFile(const QString &path, qint64 cap)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly) || f.size() > cap)
        return {};
    return f.read(cap);
}

bool writeFile(const QString &path, const QByteArray &data)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write(data) != data.size())
        return false;
    return f.commit();
}

bool isSha256(const QString &s)
{
    if (s.size() != 64)
        return false;
    return std::all_of(s.begin(), s.end(), [](QChar c) { return (c >= QLatin1Char('0') && c <= QLatin1Char('9')) || (c >= QLatin1Char('a') && c <= QLatin1Char('f')); });
}

} // namespace

CatalogStore::CatalogStore(const QString &cacheDir, const QString &stateFile, const QString &gpgv, const QString &keyringDir)
    : m_cacheDir(cacheDir)
    , m_stateFile(stateFile)
    , m_gpgv(gpgv)
    , m_keyringDir(keyringDir)
{
}

QString CatalogStore::channelDir(const QString &channel) const
{
    return m_cacheDir + QLatin1Char('/') + channel;
}

CatalogStore::Result CatalogStore::check(const QString &channel, const QByteArray &json, const QByteArray &sig) const
{
    Result r;
    if (!validChannel(channel) || json.isEmpty() || sig.isEmpty() || json.size() > kCatalogMaxBytes || sig.size() > 64 * 1024) {
        r.outcome = json.isEmpty() ? Outcome::Missing : Outcome::Refused;
        r.reason = QStringLiteral("no catalog, or one over its size bounds");
        return r;
    }
    // gpgv reads files: the bytes checked are the bytes parsed below, never read twice from a path someone else can change.
    QTemporaryDir tmp;
    if (!tmp.isValid() || !writeFile(tmp.filePath(kCatalogFile), json) || !writeFile(tmp.filePath(kCatalogFile + QStringLiteral(".sig")), sig)) {
        r.outcome = Outcome::Refused;
        r.reason = QStringLiteral("no temporary folder");
        return r;
    }
    const SignatureCheck s = verifySignature(m_gpgv, m_keyringDir, tmp.filePath(kCatalogFile), tmp.filePath(kCatalogFile + QStringLiteral(".sig")));
    switch (s.verdict) {
    case SignatureVerdict::Good:
        break;
    case SignatureVerdict::NoTrustedKey:
        r.outcome = Outcome::NoTrustedKey;
        r.reason = QStringLiteral("grassfield-keyring holds no trusted key");
        return r;
    case SignatureVerdict::Bad:
        r.outcome = Outcome::BadSignature;
        r.reason = QStringLiteral("bad or missing signature");
        return r;
    case SignatureVerdict::Untrusted:
    case SignatureVerdict::Revoked:
        r.outcome = Outcome::BadSignature;
        r.reason = QStringLiteral("signed by %1, which is %2").arg(s.signer, s.verdict == SignatureVerdict::Revoked ? QStringLiteral("revoked") : QStringLiteral("not trusted"));
        return r;
    }
    const CatalogParse parsed = parseCatalog(json, channel);
    if (!parsed.catalog) {
        r.outcome = Outcome::Refused;
        r.reason = parsed.refusal;
        return r;
    }
    if (parsed.catalog->serial < acceptedSerial(channel)) {
        r.outcome = Outcome::Replayed;
        r.reason = QStringLiteral("serial %1 is lower than the accepted %2").arg(parsed.catalog->serial).arg(acceptedSerial(channel));
        return r;
    }
    r.outcome = Outcome::Accepted;
    r.catalog = parsed.catalog;
    r.dropped = parsed.dropped;
    return r;
}

CatalogStore::Result CatalogStore::accept(const QString &channel, const QByteArray &json, const QByteArray &sig, const QByteArray &etag)
{
    Result r = check(channel, json, sig);
    if (r.outcome != Outcome::Accepted)
        return r; // not cached: the previous copy stays
    const QString dir = channelDir(channel);
    // The signature goes first: a copy with a stale .sig fails its next check, never passes it.
    if (!writeFile(dir + QStringLiteral("/") + kCatalogFile + QStringLiteral(".sig"), sig) || !writeFile(dir + QLatin1Char('/') + kCatalogFile, json)
        || !writeFile(dir + QStringLiteral("/etag"), etag.left(512))) {
        r.reason = QStringLiteral("used, but not cached: the cache folder cannot be written");
    }
    recordAccepted(channel, r.catalog->serial);
    return r;
}

CatalogStore::Result CatalogStore::loadCached(const QString &channel) const
{
    const QString dir = channelDir(channel);
    return check(channel, readFile(dir + QLatin1Char('/') + kCatalogFile, kCatalogMaxBytes),
                 readFile(dir + QLatin1Char('/') + kCatalogFile + QStringLiteral(".sig"), 64 * 1024));
}

QByteArray CatalogStore::cachedEtag(const QString &channel) const
{
    return readFile(channelDir(channel) + QStringLiteral("/etag"), 512).trimmed();
}

QDateTime CatalogStore::fetchedAt(const QString &channel) const
{
    const QJsonObject c = readStoreState(m_stateFile).value(QStringLiteral("catalog")).toObject().value(channel).toObject();
    return QDateTime::fromString(c.value(QStringLiteral("fetchedAt")).toString(), Qt::ISODate);
}

qint64 CatalogStore::acceptedSerial(const QString &channel) const
{
    const QJsonObject c = readStoreState(m_stateFile).value(QStringLiteral("catalog")).toObject().value(channel).toObject();
    return c.value(QStringLiteral("serial")).toInteger(0);
}

void CatalogStore::recordAccepted(const QString &channel, qint64 serial)
{
    updateStoreState(m_stateFile, [&](QJsonObject &state) {
        QJsonObject catalogs = state.value(QStringLiteral("catalog")).toObject();
        QJsonObject c = catalogs.value(channel).toObject();
        c.insert(QStringLiteral("serial"), std::max(serial, c.value(QStringLiteral("serial")).toInteger(0)));
        c.insert(QStringLiteral("fetchedAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
        catalogs.insert(channel, c);
        state.insert(QStringLiteral("catalog"), catalogs);
    });
}

void CatalogStore::touch(const QString &channel)
{
    recordAccepted(channel, 0);
}

bool CatalogStore::storeIcon(const CatalogIcon &icon, const QByteArray &data)
{
    if (!isSha256(icon.sha256) || data.size() != icon.bytes || data.size() > kIconMaxBytes
        || QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex() != icon.sha256.toLatin1())
        return false;
    const QString dir = m_cacheDir + QStringLiteral("/icons");
    if (!writeFile(dir + QLatin1Char('/') + icon.sha256 + QStringLiteral(".png"), data))
        return false;
    // Least recently used first, while the folder is over 32 MiB.
    QFileInfoList files = QDir(dir).entryInfoList({QStringLiteral("*.png")}, QDir::Files, QDir::Time | QDir::Reversed);
    qint64 total = 0;
    for (const QFileInfo &f : files)
        total += f.size();
    for (const QFileInfo &f : files) {
        if (total <= kIconCacheBytes)
            break;
        if (f.fileName() == icon.sha256 + QStringLiteral(".png"))
            continue;
        total -= f.size();
        QFile::remove(f.absoluteFilePath());
    }
    return true;
}

QString CatalogStore::iconPath(const CatalogIcon &icon) const
{
    if (!isSha256(icon.sha256))
        return {};
    const QString path = m_cacheDir + QStringLiteral("/icons/") + icon.sha256 + QStringLiteral(".png");
    const QByteArray data = readFile(path, kIconMaxBytes);
    if (data.size() != icon.bytes || QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex() != icon.sha256.toLatin1())
        return {};
    QFile f(path);
    if (f.open(QIODevice::ReadWrite)) // marks it used (its time orders the eviction)
        f.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
    return path;
}

} // namespace grassfield::store
