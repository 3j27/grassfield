#pragma once

#include <QJsonObject>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

// The Wi-Fi and Bluetooth sections over D-Bus (GF-049): NetworkManager (org.freedesktop.NetworkManager) and BlueZ (org.bluez), both
// on the system bus, instead of scraping `nmcli` and `bluetoothctl`. The logic here talks to a BusCaller, so the unit tests
// (tests/unit/settings/tst_systembus.cpp) run it against a canned one with no bus at all, and the integration tests
// (tests/integration/settings_dbus.sh) run it on a PRIVATE bus against fake services. The audio section stays on `wpctl`:
// PipeWire and WirePlumber have no D-Bus interface (see docs/specs/settings.md).
//
// Every call goes through one door, `guardedCall`: in a dev session (GRASSFIELD_DEV=1, a nested Hyprland on the owner's
// machine) only the read-only methods of `isReadOnlyCall` are sent, whatever asks; nothing can change the owner's network or
// Bluetooth from there. Qt Core, Qt DBus types only.
namespace grassfield::settings {

struct BusReply {
    bool ok = false;
    QVariantList args; // the reply's arguments as the bus gave them (QDBusArgument inside) or canned (plain values)
    QString error;     // "<error name>: <message>" when !ok
};

class BusCaller
{
public:
    virtual ~BusCaller() = default;
    virtual BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args,
                          int timeoutMs) = 0;
};

// The only methods a dev session may send (they read: properties, object lists, connection settings without secrets).
bool isReadOnlyCall(const QString &service, const QString &iface, const QString &member, const QVariantList &args);

// A caller that refuses, in `dev`, every call that is not read-only (BusReply{ok=false, error="dev guard: ..."}).
class GuardedCaller : public BusCaller
{
public:
    GuardedCaller(BusCaller &inner, bool dev)
        : m_inner(inner)
        , m_dev(dev)
    {
    }
    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override;

private:
    BusCaller &m_inner;
    bool m_dev;
};

// Registers the container types the readers demarshal (once per process; harmless to repeat).
void registerBusTypes();

// A short single-line reason (at most 160 characters, no control characters) for a failed call: "NetworkManager is not running",
// the service's own message, "timed out".
QString reasonOf(const QString &error);

// State for the pages, as JSON the QML parses (qml/System.js):
//   wifiState: {"radio": bool, "device": {"name", "connected"} | null,
//               "aps": [{"hex" (SSID bytes, upper-case hex), "strength" 0-100, "flags", "wpa", "rsn", "active"}],
//               "profiles": [{"uuid", "hex"}]}      (saved Wi-Fi profiles with their SSID)
//   bluetoothState: {"present": bool, "powered": bool, "devices": [{"mac", "name", "connected"}]}   (paired devices only)
// `ok` false: the service did not answer (error holds the reason); the JSON is then empty.
struct StateResult {
    bool ok = false;
    QString error;
    QJsonObject json;
};
StateResult wifiState(BusCaller &bus);
StateResult bluetoothState(BusCaller &bus);

// One action as the pages ask for it: {"op": "...", ...}; returns "" on success, else the reason. Invalid values are refused
// here (mac, uuid and SSID shapes, booleans), whatever the QML sent. Ops:
//   wifi.radio {on}, wifi.connectKnown {uuid}, wifi.connectOpen {hex}, wifi.disconnect {}, wifi.scan {},
//   bt.power {on}, bt.connect {mac, connect}
QString runAction(BusCaller &bus, const QVariantMap &op);

// Whether an action map is well formed (what runAction checks first, without touching the bus).
bool validAction(const QVariantMap &op);

} // namespace grassfield::settings
