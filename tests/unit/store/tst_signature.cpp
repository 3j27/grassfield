// The catalog's signature (ADR-0037 g, as ADR-0033 d.8): VALIDSIG's argument 10 in grassfield-trusted and not in
// grassfield-revoked. Here gpgv is a fake that prints recorded status lines; tests/integration/store_catalog.sh runs the real
// gpgv against throwaway keys in a throwaway container (RealGpgv below, given STORE_TEST_REAL_GPGV).
#include "signature.h"
#include "storetest.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

const QString kGood = QStringLiteral("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
const QString kOld = QStringLiteral("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
const QString kRogue = QStringLiteral("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC");
const QString kSub = QStringLiteral("DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD");

QByteArray validsig(const QString &primary)
{
    // Argument 1 is the signing (sub)key, argument 10 the primary key.
    return QStringLiteral("[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG 1234 Test\n[GNUPG:] VALIDSIG %1 2026-10-27 1793095200 0 4 0 22 10 00 %2\n")
        .arg(kSub, primary)
        .toLatin1();
}

struct Keyring {
    QTemporaryDir dir;
    Keyring(const QByteArray &trusted, const QByteArray &revoked, const QByteArray &keys = "not empty")
    {
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield.gpg")), keys);
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield-trusted")), trusted);
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield-revoked")), revoked);
    }
};

} // namespace

TEST(Signature, Fingerprints)
{
    const QSet<QString> f = readFingerprints(("# comment\n" + kGood + ":4:\n" + kOld + ":4:\n\nnot-a-key:4:\n" + kRogue.toLower() + ":4:\n").toLatin1());
    EXPECT_EQ(f, (QSet<QString>{kGood, kOld}));
    EXPECT_EQ(readFingerprints((kOld + "\n").toLatin1()), QSet<QString>{kOld});
}

TEST(Signature, ValidSignerIsArgumentTen)
{
    EXPECT_EQ(validSigner(validsig(kGood)), kGood);
    EXPECT_EQ(validSigner("[GNUPG:] GOODSIG 1234 Test\n"), QString());
    EXPECT_EQ(validSigner("[GNUPG:] VALIDSIG " + kGood.toLatin1() + " 2026-10-27\n"), QString()); // too short
    // Two signatures by two keys: neither is taken.
    EXPECT_EQ(validSigner(validsig(kGood) + validsig(kRogue)), QString());
    EXPECT_EQ(validSigner(validsig(kGood) + validsig(kGood)), kGood);
}

TEST(Signature, Judge)
{
    const QSet<QString> trusted{kGood, kOld}, revoked{kOld};
    EXPECT_EQ(judge(0, validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Good);
    EXPECT_EQ(judge(0, validsig(kOld), trusted, revoked).verdict, SignatureVerdict::Revoked);
    EXPECT_EQ(judge(0, validsig(kRogue), trusted, revoked).verdict, SignatureVerdict::Untrusted);
    EXPECT_EQ(judge(1, validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Bad); // gpgv's exit wins
    EXPECT_EQ(judge(0, "", trusted, revoked).verdict, SignatureVerdict::Bad);
    EXPECT_EQ(judge(0, validsig(kGood), {}, revoked).verdict, SignatureVerdict::NoTrustedKey);
}

TEST(Signature, RunsGpgvWithItsOwnEmptyHomeAndTheKeyringFolder)
{
    Keyring keyring((kGood + ":4:\n").toLatin1(), "");
    QTemporaryDir bin;
    // The fake records its arguments and GNUPGHOME, then answers like a good gpgv.
    const QString args = bin.filePath(QStringLiteral("args"));
    const QString gpgv = storetest::script(bin.filePath(QStringLiteral("gpgv")),
                                           "printf '%s\\n' \"$@\" > '" + args.toLatin1() + "'; echo \"GNUPGHOME=$GNUPGHOME LC_ALL=$LC_ALL\" >> '" + args.toLatin1()
                                               + "'\nprintf '" + validsig(kGood).replace("\n", "\\n") + "'");
    storetest::writeFile(bin.filePath(QStringLiteral("file")), "data");
    storetest::writeFile(bin.filePath(QStringLiteral("file.sig")), "sig");
    const SignatureCheck c = verifySignature(gpgv, keyring.dir.path(), bin.filePath(QStringLiteral("file")), bin.filePath(QStringLiteral("file.sig")));
    EXPECT_EQ(c.verdict, SignatureVerdict::Good);
    EXPECT_EQ(c.signer, kGood);
    QFile f(args);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QStringList lines = QString::fromUtf8(f.readAll()).split(u'\n');
    ASSERT_GE(lines.size(), 9);
    EXPECT_EQ(lines.at(0), QStringLiteral("--homedir"));
    EXPECT_TRUE(lines.at(1).startsWith(QDir::tempPath())) << lines.at(1).toStdString();
    EXPECT_NE(lines.at(1), QDir::homePath() + QStringLiteral("/.gnupg"));
    EXPECT_EQ(lines.at(2), QStringLiteral("--keyring"));
    EXPECT_EQ(lines.at(3), keyring.dir.filePath(QStringLiteral("grassfield.gpg")));
    EXPECT_EQ(lines.mid(4, 2), (QStringList{QStringLiteral("--status-fd"), QStringLiteral("1")}));
    EXPECT_EQ(lines.at(6), bin.filePath(QStringLiteral("file.sig")));
    EXPECT_EQ(lines.at(7), bin.filePath(QStringLiteral("file")));
    EXPECT_EQ(lines.at(8), QStringLiteral("GNUPGHOME=%1 LC_ALL=C").arg(lines.at(1)));
}

TEST(Signature, NoKeyMeansNoCatalog)
{
    QTemporaryDir bin;
    const QString gpgv = storetest::script(bin.filePath(QStringLiteral("gpgv")), "printf '" + validsig(kGood).replace("\n", "\\n") + "'");
    // The keyless grassfield-keyring of ADR-0033 O20: an empty keyring and an empty trusted list.
    Keyring empty("", "", "");
    EXPECT_EQ(verifySignature(gpgv, empty.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    Keyring keysButNoTrust("", "", "keys");
    EXPECT_EQ(verifySignature(gpgv, keysButNoTrust.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    EXPECT_EQ(verifySignature(gpgv, QStringLiteral("/nonexistent"), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    // gpgv missing or hanging: Bad, never Good.
    Keyring keyring((kGood + ":4:\n").toLatin1(), "");
    EXPECT_EQ(verifySignature(QStringLiteral("/nonexistent/gpgv"), keyring.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::Bad);
}

// The real gpgv, against throwaway keys made in the test container (tests/integration/store_catalog.sh). The folder holds
// grassfield.gpg, grassfield-trusted (the good key), grassfield-revoked (the revoked key), and catalog.json signed by
// each of: good.sig, revoked.sig, rogue.sig, plus changed.json (the catalog with one byte changed) under good.sig.
TEST(Signature, RealGpgv)
{
    const QString dir = qEnvironmentVariable("STORE_TEST_REAL_GPGV");
    if (dir.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    auto verify = [&](const char *file, const char *sig) {
        return verifySignature(QStringLiteral("/usr/bin/gpgv"), dir, dir + QLatin1Char('/') + QLatin1String(file), dir + QLatin1Char('/') + QLatin1String(sig)).verdict;
    };
    EXPECT_EQ(verify("catalog.json", "good.sig"), SignatureVerdict::Good);
    EXPECT_EQ(verify("catalog.json", "revoked.sig"), SignatureVerdict::Revoked);
    EXPECT_EQ(verify("catalog.json", "rogue.sig"), SignatureVerdict::Untrusted);
    EXPECT_EQ(verify("changed.json", "good.sig"), SignatureVerdict::Bad);
    EXPECT_EQ(verify("catalog.json", "catalog.json"), SignatureVerdict::Bad);
}
