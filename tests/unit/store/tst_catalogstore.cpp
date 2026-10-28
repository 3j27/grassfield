// The catalog the Store uses (ADR-0037 c, g): checked every time (signature, rules, serial), fetched or cached; a lower
// serial refused; a refused copy never replaces the accepted one. The fake gpgv here accepts a "signature" that is the
// file's SHA-256, so a changed file fails as it would with a real signature.
#include "catalogstore.h"
#include "storetest.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

const QByteArray kGood = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

QByteArray sign(const QByteArray &data)
{
    return QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex() + "\n";
}

QByteArray withSerial(qint64 serial)
{
    return storetest::changedCatalog([&](QJsonObject &o) { o[QStringLiteral("serial")] = serial; });
}

struct Fixture {
    QTemporaryDir root;
    QString gpgv, keyring, cache, state;
    Fixture()
    {
        keyring = root.filePath(QStringLiteral("keyring"));
        QDir().mkpath(keyring);
        storetest::writeFile(keyring + QStringLiteral("/grassfield.gpg"), "keys");
        storetest::writeFile(keyring + QStringLiteral("/grassfield-trusted"), kGood + ":4:\n");
        storetest::writeFile(keyring + QStringLiteral("/grassfield-revoked"), "");
        // gpgv <opts…> <sig> <file>: good when the sig holds the file's SHA-256.
        gpgv = storetest::script(root.filePath(QStringLiteral("gpgv")),
                                 "for a; do sig=$file; file=$a; done\n"
                                 "[ \"$(sha256sum \"$file\" | cut -d' ' -f1)\" = \"$(cat \"$sig\")\" ] || exit 1\n"
                                 "echo \"[GNUPG:] VALIDSIG " + kGood + " 2026-10-27 0 0 4 0 22 10 00 " + kGood + "\"");
        cache = root.filePath(QStringLiteral("cache"));
        state = root.filePath(QStringLiteral("state/store.json"));
    }
    CatalogStore store() const { return CatalogStore(cache, state, gpgv, keyring); }
};

} // namespace

TEST(CatalogStore, AcceptedCopiesAreCachedAndTheirSerialRecorded)
{
    Fixture f;
    CatalogStore s = f.store();
    const QByteArray json = withSerial(100);
    const auto r = s.accept(QStringLiteral("stable"), json, sign(json), "\"etag-1\"");
    ASSERT_EQ(r.outcome, CatalogStore::Outcome::Accepted) << r.reason.toStdString();
    EXPECT_EQ(r.catalog->serial, 100);
    EXPECT_EQ(s.acceptedSerial(QStringLiteral("stable")), 100);
    EXPECT_EQ(s.acceptedSerial(QStringLiteral("beta")), 0);
    EXPECT_EQ(s.cachedEtag(QStringLiteral("stable")), QByteArray("\"etag-1\""));
    EXPECT_TRUE(s.fetchedAt(QStringLiteral("stable")).isValid());
    const auto cached = s.loadCached(QStringLiteral("stable"));
    EXPECT_EQ(cached.outcome, CatalogStore::Outcome::Accepted);

    // store.json: version 1, other keys kept when the Store rewrites it.
    QFile state(f.state);
    ASSERT_TRUE(state.open(QIODevice::ReadOnly));
    QJsonObject o = QJsonDocument::fromJson(state.readAll()).object();
    state.close();
    EXPECT_EQ(o.value(QStringLiteral("version")).toInt(), 1);
    o.insert(QStringLiteral("operation"), QStringLiteral("kept"));
    storetest::writeFile(f.state, QJsonDocument(o).toJson());
    const QByteArray newer = withSerial(200);
    ASSERT_EQ(s.accept(QStringLiteral("stable"), newer, sign(newer), "").outcome, CatalogStore::Outcome::Accepted);
    ASSERT_TRUE(state.open(QIODevice::ReadOnly));
    EXPECT_EQ(QJsonDocument::fromJson(state.readAll()).object().value(QStringLiteral("operation")).toString(), QStringLiteral("kept"));
}

TEST(CatalogStore, AReplayedOldCatalogIsRefusedAndTheAcceptedOneStays)
{
    Fixture f;
    CatalogStore s = f.store();
    const QByteArray newer = withSerial(200), older = withSerial(100);
    ASSERT_EQ(s.accept(QStringLiteral("stable"), newer, sign(newer), "").outcome, CatalogStore::Outcome::Accepted);
    const auto r = s.accept(QStringLiteral("stable"), older, sign(older), "");
    EXPECT_EQ(r.outcome, CatalogStore::Outcome::Replayed);
    EXPECT_FALSE(r.catalog);
    EXPECT_EQ(s.acceptedSerial(QStringLiteral("stable")), 200);
    EXPECT_EQ(s.loadCached(QStringLiteral("stable")).catalog->serial, 200);
    // The same serial again is fine (a 200 that changed nothing).
    EXPECT_EQ(s.accept(QStringLiteral("stable"), newer, sign(newer), "").outcome, CatalogStore::Outcome::Accepted);
}

TEST(CatalogStore, NothingUnverifiedIsUsedOrCached)
{
    Fixture f;
    CatalogStore s = f.store();
    const QByteArray json = withSerial(100);
    EXPECT_EQ(s.accept(QStringLiteral("stable"), json, sign("other bytes"), "").outcome, CatalogStore::Outcome::BadSignature);
    EXPECT_EQ(s.loadCached(QStringLiteral("stable")).outcome, CatalogStore::Outcome::Missing);
    EXPECT_EQ(s.acceptedSerial(QStringLiteral("stable")), 0);
    // Signed, but for the other channel: refused by the rules after the signature passed.
    EXPECT_EQ(s.accept(QStringLiteral("beta"), json, sign(json), "").outcome, CatalogStore::Outcome::Refused);
    EXPECT_EQ(s.accept(QStringLiteral("nightly"), json, sign(json), "").outcome, CatalogStore::Outcome::Refused);
    // A cached copy changed after it was accepted fails its next check.
    ASSERT_EQ(s.accept(QStringLiteral("stable"), json, sign(json), "").outcome, CatalogStore::Outcome::Accepted);
    QByteArray changed = json;
    changed.replace("Discover", "Discovrr");
    storetest::writeFile(f.cache + QStringLiteral("/stable/grassfield-catalog.v1.json"), changed);
    EXPECT_EQ(s.loadCached(QStringLiteral("stable")).outcome, CatalogStore::Outcome::BadSignature);
}

TEST(CatalogStore, NoTrustedKeyNoCatalog)
{
    Fixture f;
    storetest::writeFile(f.keyring + QStringLiteral("/grassfield-trusted"), "");
    CatalogStore s = f.store();
    const QByteArray json = withSerial(100);
    EXPECT_EQ(s.accept(QStringLiteral("stable"), json, sign(json), "").outcome, CatalogStore::Outcome::NoTrustedKey);
}

TEST(CatalogStore, IconsAreKeptOnlyWithTheirListedHash)
{
    Fixture f;
    CatalogStore s = f.store();
    const QByteArray png = "\x89PNG fake icon bytes";
    CatalogIcon icon;
    icon.sha256 = QString::fromLatin1(QCryptographicHash::hash(png, QCryptographicHash::Sha256).toHex());
    icon.bytes = png.size();
    EXPECT_TRUE(s.storeIcon(icon, png));
    EXPECT_FALSE(s.iconPath(icon).isEmpty());
    CatalogIcon wrongSize = icon;
    wrongSize.bytes += 1;
    EXPECT_FALSE(s.storeIcon(wrongSize, png));
    CatalogIcon wrongHash = icon;
    wrongHash.sha256 = QString(64, u'0');
    EXPECT_FALSE(s.storeIcon(wrongHash, png));
    EXPECT_TRUE(s.iconPath(wrongHash).isEmpty());
    CatalogIcon traversal = icon;
    traversal.sha256 = QStringLiteral("../../etc/passwd");
    EXPECT_FALSE(s.storeIcon(traversal, png));
    // Changed on disk: no longer served.
    storetest::writeFile(s.iconPath(icon), "changed");
    EXPECT_TRUE(s.iconPath(icon).isEmpty());
}

TEST(CatalogStore, TheIconFolderStaysUnder32MiB)
{
    Fixture f;
    CatalogStore s = f.store();
    QStringList hashes;
    for (int i = 0; i < 140; ++i) {
        QByteArray data(256 * 1024 - 1, char('a' + i % 26));
        data.append(char(i));
        CatalogIcon icon;
        icon.sha256 = QString::fromLatin1(QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex());
        icon.bytes = data.size();
        ASSERT_TRUE(s.storeIcon(icon, data));
        hashes.append(icon.sha256);
    }
    qint64 total = 0;
    for (const QFileInfo &fi : QDir(f.cache + QStringLiteral("/icons")).entryInfoList(QDir::Files))
        total += fi.size();
    EXPECT_LE(total, 32 * 1024 * 1024);
    EXPECT_TRUE(QFile::exists(f.cache + QStringLiteral("/icons/") + hashes.last() + QStringLiteral(".png")));
}
