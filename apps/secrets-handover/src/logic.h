// The decisions of the handover that need no bus (ADR-0035 D-12, step 2c): which items move, where the marker lives, what
// it says. Unit-tested (tests/unit/secrets-handover/tst_logic.cpp).
#pragma once

#include <QDir>
#include <QMap>
#include <QString>
#include <QStringList>

namespace grassfield::handover {

using Attributes = QMap<QString, QString>;

// An item that a libsecret client saved: libsecret tags every item it stores with the schema it used ("xdg:schema"). Entries
// written through KWallet's own API carry only server, user and type (KWallet src/runtime/ksecretd/
// kwalletfreedesktopcollection.cpp, the attributes of a wallet's existing entries): they stay in KWallet for the apps that
// use KWallet.
inline bool isLibsecretItem(const Attributes &attributes)
{
    return !attributes.value(QStringLiteral("xdg:schema")).isEmpty();
}

// KWallet keeps its wallets as <name>.kwl in $XDG_DATA_HOME/kwalletd (KWallet src/runtime/kwalletbackend/kwalletbackend.cc,
// Backend::getSaveLocation). No wallet file: KWallet was never used here, and nothing is started to ask it.
inline bool hasWallet(const QString &dataHome)
{
    return !QDir(dataHome + QStringLiteral("/kwalletd")).entryList({QStringLiteral("*.kwl")}, QDir::Files).isEmpty();
}

// The marker that the handover ran to its end once for this user: $XDG_STATE_HOME/grassfield/secrets-handover.
inline QString markerPath(const QString &stateHome)
{
    return stateHome + QStringLiteral("/grassfield/secrets-handover");
}

// One line, no item, label, attribute or value: what ran and how much it moved.
inline QString markerLine(const QString &outcome, int moved, int kept)
{
    return QStringLiteral("%1 moved=%2 kept=%3\n").arg(outcome).arg(moved).arg(kept);
}

} // namespace grassfield::handover
