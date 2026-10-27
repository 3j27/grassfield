#include "signature.h"

#include "childprocess.h"

#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>

namespace grassfield::store {

namespace {

const QRegularExpression &fingerprintRe()
{
    static const QRegularExpression re(QStringLiteral(R"(\A[0-9A-F]{40}\z)"));
    return re;
}

QByteArray readSmall(const QString &path, bool *ok)
{
    QFile f(path);
    *ok = f.open(QIODevice::ReadOnly) && f.size() <= 1024 * 1024;
    return *ok ? f.readAll() : QByteArray();
}

} // namespace

std::optional<QSet<QString>> readFingerprints(const QByteArray &content)
{
    static const QRegularExpression tail(QStringLiteral(R"(\A(\d+:)?\s*\z)"));
    QSet<QString> out;
    for (const QByteArray &raw : content.split('\n')) {
        const QString line = QString::fromLatin1(raw);
        if (line.trimmed().isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        // Hand-written lists: a lower-case or space-padded entry still counts; anything else refuses the whole list.
        const qsizetype colon = line.indexOf(QLatin1Char(':'));
        const QString fpr = (colon < 0 ? line : line.left(colon)).trimmed().toUpper();
        if (!fingerprintRe().match(fpr).hasMatch() || !tail.match(colon < 0 ? QString() : line.mid(colon + 1)).hasMatch())
            return std::nullopt;
        out.insert(fpr);
    }
    return out;
}

QString validSigner(const QByteArray &status)
{
    QString signer;
    for (const QByteArray &raw : status.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(' ');
        if (f.size() >= 12 && f.at(0) == "[GNUPG:]" && f.at(1) == "VALIDSIG") {
            const QString primary = QString::fromLatin1(f.at(11)).toUpper();
            if (!fingerprintRe().match(primary).hasMatch() || (!signer.isEmpty() && signer != primary))
                return {};
            signer = primary;
        }
    }
    return signer;
}

SignatureCheck judge(int gpgvExit, const QByteArray &status, const QSet<QString> &trusted, const QSet<QString> &revoked)
{
    SignatureCheck check;
    if (trusted.isEmpty()) {
        check.verdict = SignatureVerdict::NoTrustedKey;
        return check;
    }
    check.signer = validSigner(status);
    if (gpgvExit != 0 || check.signer.isEmpty())
        check.verdict = SignatureVerdict::Bad;
    else if (revoked.contains(check.signer))
        check.verdict = SignatureVerdict::Revoked;
    else if (!trusted.contains(check.signer))
        check.verdict = SignatureVerdict::Untrusted;
    else
        check.verdict = SignatureVerdict::Good;
    return check;
}

SignatureCheck verifySignature(const QString &gpgv, const QString &keyringDir, const QString &file, const QString &sig)
{
    bool okTrusted = false, okRevoked = false;
    const QString revokedPath = keyringDir + QStringLiteral("/grassfield-revoked");
    const auto trusted = readFingerprints(readSmall(keyringDir + QStringLiteral("/grassfield-trusted"), &okTrusted));
    const auto revoked = readFingerprints(readSmall(revokedPath, &okRevoked));
    const QString keyring = keyringDir + QStringLiteral("/grassfield.gpg");
    // No revoked list is an empty one; a revoked list that is there but cannot be read whole refuses everything.
    if (!okTrusted || !trusted || trusted->isEmpty() || !revoked || (!okRevoked && QFileInfo::exists(revokedPath))
        || QFileInfo(keyring).size() == 0) {
        SignatureCheck none;
        none.verdict = SignatureVerdict::NoTrustedKey;
        return none;
    }
    // An empty home of its own: gpgv reads nothing of the user's ~/.gnupg.
    QTemporaryDir home;
    if (!home.isValid())
        return {};
    ChildOptions options;
    options.maxOut = 64 * 1024;
    options.extraEnv.insert(QStringLiteral("GNUPGHOME"), home.path());
    const ChildResult r = runChild(gpgv, {QStringLiteral("--homedir"), home.path(), QStringLiteral("--keyring"), keyring,
                                          QStringLiteral("--status-fd"), QStringLiteral("1"), sig, file},
                                   options);
    if (!r.started || r.timedOut || r.overflow)
        return {};
    return judge(r.exitCode, r.out, *trusted, *revoked);
}

} // namespace grassfield::store
