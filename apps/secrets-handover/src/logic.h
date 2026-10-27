// The decisions of the handover that need no bus (ADR-0035 D-12, step 2c): which items move, where the marker lives, what
// it says, whether the user kept KWallet, which bus a dev run may use. Unit-tested (tests/unit/secrets-handover/tst_logic.cpp).
#pragma once

#include <QDir>
#include <QFile>
#include <QMap>
#include <QString>
#include <QStringList>

namespace grassfield::handover {

using Attributes = QMap<QString, QString>;

// Every item KWallet lists moves (integrator decision in the review of fbfe34d, ADR-0035 decision 2c-10): what libsecret
// clients saved ("xdg:schema" of their schema), KWallet's own entries, which kwalletd also stores through libsecret
// (schema "org.qt.keychain": server, user, type; KWallet src/runtime/kwalletd/secretserviceclient.cpp, qtKeychainSchema), and
// entries of older KWallet versions, which ksecretd lists with server, user and type only once the wallet is open
// (src/runtime/ksecretd/kwalletfreedesktopcollection.cpp, onWalletChangeState). QtKeychain and libsecret clients look them up
// by these attributes in the Secret Service, which is the keychain in a Grassfield session. Only an item without attributes
// stays: no lookup can find it.
inline bool isFindable(const Attributes &attributes)
{
    return !attributes.isEmpty();
}

// KWallet keeps its wallets as <name>.kwl in $XDG_DATA_HOME/kwalletd (KWallet src/runtime/kwalletbackend/kwalletbackend.cc,
// Backend::getSaveLocation). No wallet file: KWallet was never used here, and nothing is started to ask it.
inline bool hasWallet(const QString &dataHome)
{
    return !QDir(dataHome + QStringLiteral("/kwalletd")).entryList({QStringLiteral("*.kwl")}, QDir::Files).isEmpty();
}

// The directory of the marker: the unit's state directory as systemd made it ($STATE_DIRECTORY, its first entry; mode 0700),
// else $XDG_STATE_HOME/grassfield.
inline QString stateDirectory(const QString &systemdStateDirectory, const QString &stateHome)
{
    const QString first = systemdStateDirectory.section(QLatin1Char(':'), 0, 0);
    return first.startsWith(QLatin1Char('/')) ? first : stateHome + QStringLiteral("/grassfield");
}

// The marker that the handover ran to its end once for this user.
inline QString markerPath(const QString &stateDir)
{
    return stateDir + QStringLiteral("/secrets-handover");
}

// One line, no item, label, attribute or value: what ran and how much it moved, kept (already in the keychain, or an older
// copy of an item that moved) and skipped (no attributes, an empty value, or a wallet left locked).
inline QString markerLine(const QString &outcome, int moved, int kept, int skipped)
{
    return QStringLiteral("%1 moved=%2 kept=%3 skipped=%4\n").arg(outcome).arg(moved).arg(kept).arg(skipped);
}

// The user's own kwalletrc gives the Secret Service back to KWallet ([org.freedesktop.secrets] apiEnabled true; KConfig reads
// it above the session's file, ADR-0035 Q17-b): the user chose KWallet, and the handover leaves both phases alone. KConfig's
// reading of a bool (true, on, yes or a non-zero number); the last entry in the file wins; "[$i]"-style markers are ignored.
inline bool userKeepsKWalletService(const QString &configHome)
{
    QFile file(configHome + QStringLiteral("/kwalletrc"));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    QString group;
    QString value;
    bool found = false;
    while (!file.atEnd()) {
        const QString line = QString::fromUtf8(file.readLine()).trimmed();
        if (line.startsWith(QLatin1Char('['))) {
            group = line.mid(1, line.indexOf(QLatin1Char(']')) - 1);
            continue;
        }
        const qsizetype eq = line.indexOf(QLatin1Char('='));
        if (group != QLatin1String("org.freedesktop.secrets") || eq <= 0)
            continue;
        if (line.left(eq).section(QLatin1Char('['), 0, 0).trimmed() == QLatin1String("apiEnabled")) {
            value = line.mid(eq + 1).trimmed().toLower();
            found = true;
        }
    }
    if (!found)
        return false;
    bool isNumber = false;
    const long number = value.toLong(&isNumber);
    return isNumber ? number != 0 : value == QLatin1String("true") || value == QLatin1String("on") || value == QLatin1String("yes");
}

// A private test bus (dev sessions only, ADR-0019: the overrides of the tests apply only there): every ';' entry of the
// address is unix:path=<a socket under `dir`> (percent-escapes decoded, dots resolved) or tcp on loopback. The rule of
// tests/integration/settings_dbus/probe.cpp and of the fakes (tests/fixtures/fake-secret-service.py).
inline bool isPrivateTestBus(const QString &address, const QString &dir)
{
    if (address.isEmpty() || !dir.startsWith(QLatin1Char('/')))
        return false;
    const QString root = QDir::cleanPath(dir);
    const QStringList entries = address.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    if (entries.isEmpty())
        return false;
    for (const QString &entry : entries) {
        const qsizetype colon = entry.indexOf(QLatin1Char(':'));
        if (colon <= 0)
            return false;
        const QString transport = entry.left(colon);
        QMap<QString, QString> kv;
        for (const QString &pair : entry.mid(colon + 1).split(QLatin1Char(','), Qt::SkipEmptyParts)) {
            const qsizetype eq = pair.indexOf(QLatin1Char('='));
            if (eq <= 0)
                return false;
            kv.insert(pair.left(eq), QString::fromUtf8(QByteArray::fromPercentEncoding(pair.mid(eq + 1).toUtf8())));
        }
        if (transport == QLatin1String("unix")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("path") && it.key() != QLatin1String("guid"))
                    return false;
            const QString path = kv.value(QStringLiteral("path"));
            if (!path.startsWith(QLatin1Char('/')) || !QDir::cleanPath(path).startsWith(root + QLatin1Char('/')))
                return false;
        } else if (transport == QLatin1String("tcp")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("host") && it.key() != QLatin1String("port") && it.key() != QLatin1String("family")
                    && it.key() != QLatin1String("guid"))
                    return false;
            const QString host = kv.value(QStringLiteral("host"));
            if (host != QLatin1String("127.0.0.1") && host != QLatin1String("localhost") && host != QLatin1String("::1"))
                return false;
        } else {
            return false;
        }
    }
    return true;
}

} // namespace grassfield::handover
