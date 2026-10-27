// The catalog's signature (ADR-0037 g "Signature and verification"), checked exactly as ADR-0033 d.8 checks the release
// notes: gpgv with the keyring of grassfield-keyring's private folder (/usr/share/grassfield/pacman-keyring/, ADR-0033 b.2),
// the signer being VALIDSIG's argument 10 (the primary key's fingerprint), listed in grassfield-trusted and absent from
// grassfield-revoked. It reads those files, not pacman's keyring, so it works whether Grassfield updates are on or not.
#pragma once

#include <QByteArray>
#include <QSet>
#include <QString>

#include <optional>

namespace grassfield::store {

inline const QString kKeyringDir = QStringLiteral("/usr/share/grassfield/pacman-keyring");

enum class SignatureVerdict {
    Good,
    NoTrustedKey, // grassfield-keyring holds no key yet (until the owner's key exists, ADR-0033 O20), is missing, or
                  // one of its lists cannot be read whole
    Bad,          // gpgv refused it, or gave no VALIDSIG: a changed file, another key, no signature
    Untrusted,    // a good signature by a key grassfield-trusted does not list
    Revoked,      // a good signature by a key grassfield-revoked lists
};

struct SignatureCheck {
    SignatureVerdict verdict = SignatureVerdict::Bad;
    QString signer; // the primary key's fingerprint, when gpgv gave one
};

// "<40 hex>:4:" lines of grassfield-trusted (pacman's format), or bare fingerprints (grassfield-revoked), in upper case
// with the spaces around them ignored; blank lines and lines starting with '#' are skipped. Empty when any other line is
// there (a grouped fingerprint, a 0x prefix, a trailing comment): a list that cannot be read whole is not used, so a
// revoked entry written another way never leaves its key trusted (the same rule as tools/catalog.py).
std::optional<QSet<QString>> readFingerprints(const QByteArray &content);
// VALIDSIG's argument 10 in gpgv's --status-fd output ("" when there is none, or more than one signer).
QString validSigner(const QByteArray &status);
// The verdict from gpgv's exit code, its status lines and the two lists (pure: the tests feed it recorded outputs). A
// PLAINTEXT line refuses it: the .sig must be a detached signature, never a signed message of its own.
SignatureCheck judge(int gpgvExit, const QByteArray &status, const QSet<QString> &trusted, const QSet<QString> &revoked);

// Runs `gpgv --homedir <empty temporary folder> --keyring <dir>/grassfield.gpg --status-fd 1 <sig> <file>`.
// gpgv: the program (an absolute path; "/usr/bin/gpgv" in a real session, a fake one in tests).
SignatureCheck verifySignature(const QString &gpgv, const QString &keyringDir, const QString &file, const QString &sig);

// A package of Arch's mirror checked as pacman checks it (ADR-0037 c, SD4; S19): gpg --verify against a private copy of
// pacman's public keyring and trust database (pubring.gpg or pubring.kbx, trustdb.gpg; never written in place). It passes
// only with exactly one good detached signature (one VALIDSIG), its key fully or ultimately valid (TRUST_FULLY or
// TRUST_ULTIMATE, pacman's rule), the key not disabled in that keyring (pacman-key --populate disables revoked packagers:
// gpg still says TRUST_FULLY for them, only the key listing's flags say D), and none of PLAINTEXT, BADSIG, ERRSIG, EXPSIG,
// EXPKEYSIG, REVKEYSIG. pacman-key --verify's exit code is not used: in pacman 7.1.0 it is 0 for a good signature by any
// key of the keyring, trusted or not (S19).
inline const QString kPacmanGnupg = QStringLiteral("/etc/pacman.d/gnupg");
// Pure: gpg's exit code and --status-fd lines; the primary key's fingerprint when they pass, else "".
QString pacmanTrustedSigner(int gpgExit, const QByteArray &status);
// Pure: `gpg --with-colons --list-keys <fpr>`; true when it lists that one key, valid (f or u) and not disabled.
bool pacmanKeyUsable(const QByteArray &colons, const QString &fingerprint);
bool verifyPacmanSignature(const QString &gpg, const QString &pacmanGnupg, const QString &file, const QString &sig,
                           QString *why);

} // namespace grassfield::store
