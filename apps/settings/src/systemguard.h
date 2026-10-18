#pragma once

#include <QString>
#include <QStringList>

// Dev guard of the system sections (Wi-Fi, Bluetooth, Sound, Displays). In a dev session (GRASSFIELD_DEV=1, a nested
// Hyprland on the owner's machine) nothing may change the owner's network, Bluetooth, audio or monitors: only the
// read-only queries below may run. Kept free of QML and QObject so the rule is easy to read and to test.
namespace grassfield::settings {

// GRASSFIELD_DEV === "1", like Quickshell.env("GRASSFIELD_DEV") in the shell services.
bool devSession();

// Exactly the read-only queries the pages issue (qml/System.js builds the same argument vectors). Anything else,
// also a variation of these, is not a query.
bool isReadOnlyQuery(const QStringList &argv);

// Programs the pages may run as actions in a real session. Anything else is refused.
bool isActionProgram(const QString &program);

// A device id of `wpctl` (digits) or one of its @DEFAULT_...@ names.
bool isWpctlTarget(const QString &s);

} // namespace grassfield::settings
