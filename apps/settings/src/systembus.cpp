#include "systembus.h"

#include "systemguard.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QJsonArray>
#include <QMap>
#include <QRegularExpression>
#include <QThread>

namespace grassfield::settings {

namespace {
using ConnectionSettings = QMap<QString, QVariantMap>;
using ManagedObjects = QMap<QDBusObjectPath, ConnectionSettings>;

constexpr int kReadMs = 3000;
constexpr int kActMs = 30000; // a Bluetooth connect or a Wi-Fi association can take a while
constexpr int kPrivilegedMs = 120000; // the service asks the polkit agent first: the user reads the dialog and types a password
constexpr int kMaxReason = 160;

const QString kProps = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kNmService = QStringLiteral("org.freedesktop.NetworkManager");
const QString kNmPath = QStringLiteral("/org/freedesktop/NetworkManager");
const QString kNmIface = QStringLiteral("org.freedesktop.NetworkManager");
const QString kNmDevice = QStringLiteral("org.freedesktop.NetworkManager.Device");
const QString kNmWireless = QStringLiteral("org.freedesktop.NetworkManager.Device.Wireless");
const QString kNmAp = QStringLiteral("org.freedesktop.NetworkManager.AccessPoint");
const QString kNmSettingsPath = QStringLiteral("/org/freedesktop/NetworkManager/Settings");
const QString kNmSettings = QStringLiteral("org.freedesktop.NetworkManager.Settings");
const QString kNmConnection = QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection");
const QString kNmIp4 = QStringLiteral("org.freedesktop.NetworkManager.IP4Config");
const QString kNmIp6 = QStringLiteral("org.freedesktop.NetworkManager.IP6Config");
const QString kNmActive = QStringLiteral("org.freedesktop.NetworkManager.Connection.Active");
const QString kBluez = QStringLiteral("org.bluez");
const QString kObjectManager = QStringLiteral("org.freedesktop.DBus.ObjectManager");
const QString kAdapter = QStringLiteral("org.bluez.Adapter1");
const QString kDevice1 = QStringLiteral("org.bluez.Device1");
// The General pane's services (ADR-0026).
const QString kHostService = QStringLiteral("org.freedesktop.hostname1");
const QString kHostPath = QStringLiteral("/org/freedesktop/hostname1");
const QString kTimeService = QStringLiteral("org.freedesktop.timedate1");
const QString kTimePath = QStringLiteral("/org/freedesktop/timedate1");
const QString kSyncService = QStringLiteral("org.freedesktop.timesync1");
const QString kSyncPath = QStringLiteral("/org/freedesktop/timesync1");
const QString kSyncManager = QStringLiteral("org.freedesktop.timesync1.Manager");
const QString kLocaleService = QStringLiteral("org.freedesktop.locale1");
const QString kLocalePath = QStringLiteral("/org/freedesktop/locale1");
const QString kSystemd = QStringLiteral("org.freedesktop.systemd1");
const QString kSystemdPath = QStringLiteral("/org/freedesktop/systemd1");
const QString kSystemdManager = QStringLiteral("org.freedesktop.systemd1.Manager");

constexpr uint kDeviceTypeWifi = 2;
constexpr uint kDeviceStateActivated = 100;

// A value as the bus gives it (a QDBusArgument inside the variant: read by streaming) or as a canned reply has it (the value).
template<typename T>
T cast(const QVariant &v)
{
    if (v.metaType() == QMetaType::fromType<QDBusArgument>())
        return qdbus_cast<T>(qvariant_cast<QDBusArgument>(v));
    return qvariant_cast<T>(v);
}

// A property value as the bus gives it (a QDBusVariant) or as a canned reply has it (the value itself).
QVariant unwrap(const QVariant &v)
{
    if (v.metaType() == QMetaType::fromType<QDBusVariant>())
        return qvariant_cast<QDBusVariant>(v).variant();
    return v;
}

struct Result {
    bool ok = false;
    QVariant value;
    QString error;
};

Result property(BusCaller &bus, const QString &service, const QString &path, const QString &iface, const QString &name)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("Get"), {iface, name}, kReadMs);
    if (!r.ok || r.args.isEmpty())
        return {false, {}, r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error};
    return {true, unwrap(r.args.first()), {}};
}

struct Props {
    bool ok = false;
    QVariantMap map;
    QString error;
};

Props allProperties(BusCaller &bus, const QString &service, const QString &path, const QString &iface)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("GetAll"), {iface}, kReadMs);
    if (!r.ok || r.args.isEmpty())
        return {false, {}, r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error};
    return {true, cast<QVariantMap>(r.args.first()), {}};
}

QList<QDBusObjectPath> paths(const BusReply &r)
{
    return r.ok && !r.args.isEmpty() ? cast<QList<QDBusObjectPath>>(r.args.first()) : QList<QDBusObjectPath>();
}

QString upperHex(const QByteArray &bytes)
{
    return QString::fromLatin1(bytes.toHex().toUpper());
}

// The first Wi-Fi device: its path, and its Device properties.
struct WifiDevice {
    bool found = false;
    QString path;
    QVariantMap props;
};

WifiDevice firstWifiDevice(BusCaller &bus, QString *error)
{
    const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("GetDevices"), {}, kReadMs);
    if (!r.ok) {
        *error = r.error;
        return {};
    }
    for (const QDBusObjectPath &p : paths(r)) {
        const Props props = allProperties(bus, kNmService, p.path(), kNmDevice);
        if (props.ok && props.map.value(QStringLiteral("DeviceType")).toUInt() == kDeviceTypeWifi)
            return {true, p.path(), props.map};
    }
    return {};
}

struct AccessPoint {
    QString path;
    QByteArray ssid;
    int strength = 0;
    uint flags = 0, wpa = 0, rsn = 0;
};

QList<AccessPoint> accessPoints(BusCaller &bus, const QString &devicePath)
{
    QList<AccessPoint> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, devicePath, kNmWireless, QStringLiteral("GetAllAccessPoints"), {}, kReadMs))) {
        const Props props = allProperties(bus, kNmService, p.path(), kNmAp);
        if (!props.ok)
            continue; // the access point went away between the two calls
        AccessPoint ap;
        ap.path = p.path();
        ap.ssid = cast<QByteArray>(props.map.value(QStringLiteral("Ssid")));
        ap.strength = props.map.value(QStringLiteral("Strength")).toInt();
        ap.flags = props.map.value(QStringLiteral("Flags")).toUInt();
        ap.wpa = props.map.value(QStringLiteral("WpaFlags")).toUInt();
        ap.rsn = props.map.value(QStringLiteral("RsnFlags")).toUInt();
        out.append(ap);
    }
    return out;
}

// NM_802_11_AP_SEC_KEY_MGMT_*: PSK 0x100, 802.1X 0x200, SAE 0x400, OWE 0x800, OWE transition 0x1000, Suite-B 0x2000.
constexpr uint kKeyMgmtNeedsCredentials = 0x100 | 0x200 | 0x400 | 0x2000;
constexpr uint kKeyMgmtOwe = 0x800;

// Enhanced Open (OWE): encrypted without a password, like an open network for the person joining it (Apple's platform security
// guide calls it improved security "on open networks", "unauthenticated networks"). The access point offers OWE and nothing
// that asks for a key or an account.
bool isOwe(const AccessPoint &ap)
{
    return ap.wpa == 0 && (ap.rsn & kKeyMgmtOwe) != 0 && (ap.rsn & kKeyMgmtNeedsCredentials) == 0;
}

constexpr uint kKeyMgmtOweTransition = 0x1000;

// Whether joining needs a password or an account: WPA/WPA2/WPA3/802.1X (or any other key management), or WEP (privacy flag with
// no WPA/RSN information at all). Enhanced Open does not, and neither does the open side of OWE transition mode (RsnFlags 0x1000
// only). This is the rule of System.wifiSecurity: the label ("" or "OWE" = no lock, joins with a click) and the join agree.
bool needsCredentials(const AccessPoint &ap)
{
    if (isOwe(ap))
        return false;
    return ap.wpa != 0 || (ap.rsn & ~kKeyMgmtOweTransition) != 0 || ((ap.flags & 1) != 0 && ap.rsn == 0);
}

struct Profile {
    QString path;
    QString uuid;
    QByteArray ssid;
};

QList<Profile> wifiProfiles(BusCaller &bus)
{
    QList<Profile> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, kNmSettingsPath, kNmSettings, QStringLiteral("ListConnections"), {}, kReadMs))) {
        const BusReply r = bus.call(kNmService, p.path(), kNmConnection, QStringLiteral("GetSettings"), {}, kReadMs);
        if (!r.ok || r.args.isEmpty())
            continue;
        const ConnectionSettings s = cast<ConnectionSettings>(r.args.first());
        if (s.value(QStringLiteral("connection")).value(QStringLiteral("type")).toString() != QLatin1String("802-11-wireless"))
            continue;
        Profile profile;
        profile.path = p.path();
        profile.uuid = s.value(QStringLiteral("connection")).value(QStringLiteral("uuid")).toString();
        profile.ssid = cast<QByteArray>(s.value(QStringLiteral("802-11-wireless")).value(QStringLiteral("ssid")));
        out.append(profile);
    }
    return out;
}

ManagedObjects bluezObjects(BusCaller &bus, QString *error)
{
    const BusReply r = bus.call(kBluez, QStringLiteral("/"), kObjectManager, QStringLiteral("GetManagedObjects"), {}, kReadMs);
    if (!r.ok || r.args.isEmpty()) {
        *error = r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error;
        return {};
    }
    return cast<ManagedObjects>(r.args.first());
}

QString firstAdapterPath(const ManagedObjects &objects)
{
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        if (it.value().contains(kAdapter))
            return it.key().path();
    }
    return {};
}

bool isMac(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")));
    return re.match(s).hasMatch();
}

bool isSsidHex(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("([0-9A-Fa-f]{2}){1,32}")));
    return re.match(s).hasMatch();
}

// A WPA/WPA3 personal passphrase as NetworkManager takes it: 8 to 63 printable ASCII characters, or the 64 hex digits of a
// raw key.
bool isPassphrase(const QVariant &v)
{
    if (v.metaType() != QMetaType::fromType<QString>())
        return false;
    static const QRegularExpression ascii(QRegularExpression::anchoredPattern(QStringLiteral("[\\x20-\\x7E]{8,63}")));
    static const QRegularExpression raw(QRegularExpression::anchoredPattern(QStringLiteral("[0-9A-Fa-f]{64}")));
    const QString s = v.toString();
    return ascii.match(s).hasMatch() || raw.match(s).hasMatch();
}

bool isBool(const QVariant &v)
{
    return v.metaType() == QMetaType::fromType<bool>();
}

QString fail(const QString &error)
{
    const QString r = reasonOf(error);
    return r.isEmpty() ? QCoreApplication::translate("SystemBus", "failed") : r;
}

QString setProperty(BusCaller &bus, const QString &service, const QString &path, const QString &iface, const QString &name, const QVariant &value)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("Set"), {iface, name, QVariant::fromValue(QDBusVariant(value))}, kActMs);
    return r.ok ? QString() : fail(r.error);
}

// A string a service gave, for showing: control characters dropped, at most 256 characters.
QString clean(const QVariant &v)
{
    QString t = unwrap(v).toString();
    t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
    return t.left(256);
}

QStringList strings(const QVariant &v)
{
    const QVariant u = unwrap(v);
    QStringList out;
    for (const QString &t : cast<QStringList>(u))
        out << clean(t);
    return out;
}

QJsonArray jsonStrings(const QStringList &list)
{
    QJsonArray a;
    for (const QString &t : list)
        a.append(t);
    return a;
}

// systemd's a(ss) of ListUnitFilesByPatterns: (path, state), from the bus (a QDBusArgument) or canned ([[path, state], ...]).
QList<QPair<QString, QString>> unitFiles(const QVariant &v)
{
    QList<QPair<QString, QString>> out;
    if (v.metaType() == QMetaType::fromType<QDBusArgument>()) {
        const QDBusArgument arg = qvariant_cast<QDBusArgument>(v);
        arg.beginArray();
        while (!arg.atEnd()) {
            QString path, state;
            arg.beginStructure();
            arg >> path >> state;
            arg.endStructure();
            out.append({path, state});
        }
        arg.endArray();
        return out;
    }
    for (const QVariant &e : v.toList()) {
        const QVariantList pair = e.toList();
        if (pair.size() == 2)
            out.append({pair.at(0).toString(), pair.at(1).toString()});
    }
    return out;
}

// A time zone name as timedate1 takes it: Area/Location (letters, digits, '_', '-', '+'), at most 64 characters.
bool isZone(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,3}"))); // anchored: "$" alone would let a final newline through
    return s.size() <= 64 && re.match(s).hasMatch();
}

// A computer name: 1 to 64 characters, none of them a control character.
bool isComputerName(const QString &s)
{
    static const QRegularExpression control(QStringLiteral("[\\x00-\\x1f\\x7f]"));
    return !s.trimmed().isEmpty() && s.size() <= 64 && !control.match(s).hasMatch();
}

// Microseconds since the epoch, as a decimal string, between 2000-01-01 and 2200-01-01.
bool isUsec(const QVariant &v, qint64 *out)
{
    const QString t = v.toString();
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[0-9]{15,17}")));
    if (v.metaType() != QMetaType::fromType<QString>() || !re.match(t).hasMatch())
        return false;
    bool ok = false;
    const qint64 value = t.toLongLong(&ok);
    if (!ok || value < 946684800000000LL || value > 7258118400000000LL)
        return false;
    if (out)
        *out = value;
    return true;
}

// A user service's unit name: letters, digits, ':', '_', '.', '@', '-', ending in ".service"; at most 200 characters.
bool isUserUnit(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9:_.@-]+\\.service")));
    return s.size() <= 200 && re.match(s).hasMatch();
}

QString privileged(BusCaller &bus, const QString &service, const QString &path, const QString &member, const QVariantList &args)
{
    const BusReply r = bus.call(service, path, service, member, args, kPrivilegedMs);
    return r.ok ? QString() : fail(r.error);
}
} // namespace

void registerBusTypes()
{
    static const bool once = [] {
        qDBusRegisterMetaType<ConnectionSettings>();
        qDBusRegisterMetaType<ManagedObjects>();
        return true;
    }();
    Q_UNUSED(once)
}

bool isReadOnlyCall(const QString &service, const QString &iface, const QString &member, const QVariantList &args)
{
    Q_UNUSED(args)
    // The General pane's services: their properties, the list of time zones and the user's unit files.
    if (service == kHostService || service == kTimeService || service == kSyncService || service == kLocaleService) {
        if (iface == kProps)
            return member == QLatin1String("Get") || member == QLatin1String("GetAll");
        return service == kTimeService && iface == kTimeService && member == QLatin1String("ListTimezones");
    }
    if (service == kSystemd)
        return (iface == kProps && (member == QLatin1String("Get") || member == QLatin1String("GetAll")))
            || (iface == kSystemdManager && member == QLatin1String("ListUnitFilesByPatterns"));
    if (service != kNmService && service != kBluez)
        return false;
    if (iface == kProps)
        return member == QLatin1String("Get") || member == QLatin1String("GetAll");
    if (service == kBluez)
        return iface == kObjectManager && member == QLatin1String("GetManagedObjects");
    return (iface == kNmIface && member == QLatin1String("GetDevices")) || (iface == kNmWireless && member == QLatin1String("GetAllAccessPoints"))
        || (iface == kNmSettings && member == QLatin1String("ListConnections")) || (iface == kNmConnection && member == QLatin1String("GetSettings"));
}

BusReply GuardedCaller::call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs)
{
    if (m_dev && !isReadOnlyCall(service, iface, member, args)) {
        BusReply r;
        r.error = QStringLiteral("dev guard: %1.%2 suppressed").arg(iface, member); // i18n-ignore: a log line
        return r;
    }
    return m_inner.call(service, path, iface, member, args, timeoutMs);
}

QString reasonOf(const QString &error)
{
    if (error.contains(QLatin1String("ServiceUnknown")) || error.contains(QLatin1String("NameHasNoOwner")))
        return QCoreApplication::translate("SystemBus", "the service is not running");
    if (error.contains(QLatin1String("NoReply")) || error.contains(QLatin1String("Timeout")) || error.contains(QLatin1String("timed out"))) // i18n-ignore: a match on the error text
        return QCoreApplication::translate("SystemBus", "timed out");
    if (error.contains(QLatin1String("AccessDenied")) || error.contains(QLatin1String("NotAuthorized")) || error.contains(QLatin1String("PermissionDenied")))
        return QCoreApplication::translate("SystemBus", "not allowed: the system refused the request");
    if (error.contains(QLatin1String("NoServer")))
        return QCoreApplication::translate("SystemBus", "no connection to the system bus");
    QString t = error;
    const int colon = t.indexOf(QLatin1String(": "));
    if (colon >= 0 && t.left(colon).contains(QLatin1Char('.')))
        t = t.mid(colon + 2);
    t = t.simplified();
    t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
    return t.left(kMaxReason);
}

StateResult wifiState(BusCaller &bus)
{
    StateResult r;
    const Result radio = property(bus, kNmService, kNmPath, kNmIface, QStringLiteral("WirelessEnabled"));
    if (!radio.ok) {
        r.error = reasonOf(radio.error);
        return r;
    }
    QString error;
    const WifiDevice dev = firstWifiDevice(bus, &error);
    QJsonObject out;
    out.insert(QStringLiteral("radio"), radio.value.toBool());
    QJsonArray aps;
    if (dev.found) {
        out.insert(QStringLiteral("device"), QJsonObject{{QStringLiteral("name"), dev.props.value(QStringLiteral("Interface")).toString()},
                                                         {QStringLiteral("connected"), dev.props.value(QStringLiteral("State")).toUInt() == kDeviceStateActivated}});
        if (radio.value.toBool()) {
            const Result active = property(bus, kNmService, dev.path, kNmWireless, QStringLiteral("ActiveAccessPoint"));
            const QString activePath = active.ok ? cast<QDBusObjectPath>(active.value).path() : QString();
            for (const AccessPoint &ap : accessPoints(bus, dev.path)) {
                aps.append(QJsonObject{{QStringLiteral("hex"), upperHex(ap.ssid)},
                                       {QStringLiteral("strength"), ap.strength},
                                       {QStringLiteral("flags"), static_cast<qint64>(ap.flags)},
                                       {QStringLiteral("wpa"), static_cast<qint64>(ap.wpa)},
                                       {QStringLiteral("rsn"), static_cast<qint64>(ap.rsn)},
                                       {QStringLiteral("active"), ap.path == activePath && activePath != QLatin1String("/")}});
            }
        }
    } else {
        out.insert(QStringLiteral("device"), QJsonValue::Null);
    }
    out.insert(QStringLiteral("aps"), aps);
    QJsonArray profiles;
    for (const Profile &p : wifiProfiles(bus))
        profiles.append(QJsonObject{{QStringLiteral("uuid"), p.uuid}, {QStringLiteral("hex"), upperHex(p.ssid)}});
    out.insert(QStringLiteral("profiles"), profiles);
    r.ok = true;
    r.json = out;
    return r;
}

namespace {
constexpr uint kDeviceTypeEthernet = 1;

// An aa{sv} property (IP4Config AddressData, NameserverData) from the bus (a QDBusArgument) or canned (a list of maps).
QList<QVariantMap> mapList(const QVariant &v)
{
    const QVariant u = unwrap(v);
    QList<QVariantMap> out;
    if (u.metaType() == QMetaType::fromType<QDBusArgument>()) {
        const QDBusArgument arg = qvariant_cast<QDBusArgument>(u);
        arg.beginArray();
        while (!arg.atEnd()) {
            QVariantMap m;
            arg >> m;
            out.append(m);
        }
        arg.endArray();
        return out;
    }
    for (const QVariant &e : u.toList())
        out.append(e.toMap());
    return out;
}

// "connected", "connecting", "disconnected" or "unavailable" from NM_DEVICE_STATE (10 unmanaged, 20 unavailable, 30
// disconnected, 40-90 on the way, 100 activated, 110 deactivating, 120 failed).
QString deviceState(uint state)
{
    if (state == kDeviceStateActivated)
        return QStringLiteral("connected"); // i18n-ignore: a state the page reads, not shown
    if (state >= 40 && state < 100)
        return QStringLiteral("connecting"); // i18n-ignore: a state the page reads, not shown
    if (state <= 20)
        return QStringLiteral("unavailable"); // i18n-ignore: a state the page reads, not shown
    return QStringLiteral("disconnected"); // i18n-ignore: a state the page reads, not shown
}

// An IP4Config or IP6Config object: its addresses ("a/n"), its gateway and (IPv4) its name servers.
void addIpConfig(BusCaller &bus, const QString &path, bool v6, QJsonObject *out)
{
    if (path.isEmpty() || path == QLatin1String("/"))
        return;
    const Props p = allProperties(bus, kNmService, path, v6 ? kNmIp6 : kNmIp4);
    if (!p.ok)
        return;
    QStringList addresses;
    for (const QVariantMap &a : mapList(p.map.value(QStringLiteral("AddressData")))) {
        const QString address = clean(a.value(QStringLiteral("address")));
        if (!address.isEmpty())
            addresses << address + QLatin1Char('/') + QString::number(unwrap(a.value(QStringLiteral("prefix"))).toUInt());
    }
    out->insert(v6 ? QStringLiteral("ip6") : QStringLiteral("ip4"), jsonStrings(addresses));
    out->insert(v6 ? QStringLiteral("router6") : QStringLiteral("router"), clean(p.map.value(QStringLiteral("Gateway")))); // i18n-ignore: JSON keys of net.state
    if (!v6) {
        QStringList dns;
        for (const QVariantMap &n : mapList(p.map.value(QStringLiteral("NameserverData")))) {
            const QString address = clean(n.value(QStringLiteral("address")));
            if (!address.isEmpty())
                dns << address;
        }
        out->insert(QStringLiteral("dns"), jsonStrings(dns));
    }
}

QString connectionState(uint state)
{
    // NM_ACTIVE_CONNECTION_STATE: 1 activating, 2 activated, 3 deactivating, 4 deactivated.
    return state == 2 ? QStringLiteral("connected") : state == 1 ? QStringLiteral("connecting") : QStringLiteral("disconnected"); // i18n-ignore: states the page reads, not shown
}

// A saved profile of any type: its object path, uuid, name and type.
struct AnyProfile {
    QString path, uuid, id, type;
};

QList<AnyProfile> allProfiles(BusCaller &bus)
{
    QList<AnyProfile> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, kNmSettingsPath, kNmSettings, QStringLiteral("ListConnections"), {}, kReadMs))) {
        const BusReply r = bus.call(kNmService, p.path(), kNmConnection, QStringLiteral("GetSettings"), {}, kReadMs);
        if (!r.ok || r.args.isEmpty())
            continue;
        const QVariantMap c = cast<ConnectionSettings>(r.args.first()).value(QStringLiteral("connection"));
        out.append({p.path(), c.value(QStringLiteral("uuid")).toString(), clean(c.value(QStringLiteral("id"))), c.value(QStringLiteral("type")).toString()});
    }
    return out;
}

// The active connections: uuid -> {object path, NM_ACTIVE_CONNECTION_STATE}.
QMap<QString, QPair<QString, uint>> activeConnections(BusCaller &bus)
{
    QMap<QString, QPair<QString, uint>> out;
    const Result active = property(bus, kNmService, kNmPath, kNmIface, QStringLiteral("ActiveConnections"));
    if (!active.ok)
        return out;
    for (const QDBusObjectPath &p : cast<QList<QDBusObjectPath>>(active.value)) {
        const Props a = allProperties(bus, kNmService, p.path(), kNmActive);
        if (a.ok)
            out.insert(a.map.value(QStringLiteral("Uuid")).toString().toLower(), {p.path(), a.map.value(QStringLiteral("State")).toUInt()});
    }
    return out;
}
} // namespace

StateResult networkState(BusCaller &bus)
{
    StateResult r;
    const BusReply list = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("GetDevices"), {}, kReadMs);
    if (!list.ok) {
        r.error = reasonOf(list.error);
        return r;
    }
    QJsonArray devices;
    for (const QDBusObjectPath &p : paths(list)) {
        const Props d = allProperties(bus, kNmService, p.path(), kNmDevice);
        const uint type = d.map.value(QStringLiteral("DeviceType")).toUInt();
        if (!d.ok || (type != kDeviceTypeEthernet && type != kDeviceTypeWifi))
            continue;
        const uint state = d.map.value(QStringLiteral("State")).toUInt();
        QJsonObject dev{{QStringLiteral("name"), clean(d.map.value(QStringLiteral("Interface")))},
                        {QStringLiteral("type"), type == kDeviceTypeWifi ? QStringLiteral("wifi") : QStringLiteral("ethernet")}, // i18n-ignore: device types the page reads
                        {QStringLiteral("state"), deviceState(state)},
                        {QStringLiteral("mac"), clean(d.map.value(QStringLiteral("HwAddress")))}};
        const QString activePath = cast<QDBusObjectPath>(d.map.value(QStringLiteral("ActiveConnection"))).path();
        if (!activePath.isEmpty() && activePath != QLatin1String("/")) {
            const Props a = allProperties(bus, kNmService, activePath, kNmActive);
            if (a.ok) {
                dev.insert(QStringLiteral("connection"), clean(a.map.value(QStringLiteral("Id"))));
                dev.insert(QStringLiteral("uuid"), clean(a.map.value(QStringLiteral("Uuid"))));
            }
        }
        if (state == kDeviceStateActivated) {
            addIpConfig(bus, cast<QDBusObjectPath>(d.map.value(QStringLiteral("Ip4Config"))).path(), false, &dev);
            addIpConfig(bus, cast<QDBusObjectPath>(d.map.value(QStringLiteral("Ip6Config"))).path(), true, &dev);
            if (type == kDeviceTypeWifi) {
                const Props w = allProperties(bus, kNmService, p.path(), kNmWireless);
                if (w.ok) {
                    dev.insert(QStringLiteral("bitrate"), static_cast<qint64>(w.map.value(QStringLiteral("Bitrate")).toUInt()));
                    const QString ap = cast<QDBusObjectPath>(w.map.value(QStringLiteral("ActiveAccessPoint"))).path();
                    const Props a = ap.isEmpty() || ap == QLatin1String("/") ? Props() : allProperties(bus, kNmService, ap, kNmAp);
                    if (a.ok) {
                        dev.insert(QStringLiteral("frequency"), static_cast<qint64>(a.map.value(QStringLiteral("Frequency")).toUInt()));
                        dev.insert(QStringLiteral("ssid"), upperHex(cast<QByteArray>(a.map.value(QStringLiteral("Ssid")))));
                    }
                }
            }
        }
        devices.append(dev);
    }
    QJsonArray vpns;
    const QMap<QString, QPair<QString, uint>> active = activeConnections(bus);
    for (const AnyProfile &p : allProfiles(bus)) {
        if (p.type != QLatin1String("vpn") && p.type != QLatin1String("wireguard"))
            continue;
        const auto a = active.constFind(p.uuid.toLower());
        vpns.append(QJsonObject{{QStringLiteral("uuid"), p.uuid}, {QStringLiteral("name"), p.id},
                                {QStringLiteral("kind"), p.type}, {QStringLiteral("state"), a == active.cend() ? QStringLiteral("disconnected") : connectionState(a->second)}}); // i18n-ignore: a state the page reads
    }
    r.json = QJsonObject{{QStringLiteral("devices"), devices}, {QStringLiteral("vpns"), vpns}};
    r.ok = true;
    return r;
}

StateResult bluetoothState(BusCaller &bus)
{
    StateResult r;
    QString error;
    const ManagedObjects objects = bluezObjects(bus, &error);
    if (!error.isEmpty()) {
        r.error = reasonOf(error);
        return r;
    }
    const QString adapter = firstAdapterPath(objects);
    QJsonObject out{{QStringLiteral("present"), !adapter.isEmpty()}, {QStringLiteral("powered"), false}};
    QJsonArray devices;
    if (!adapter.isEmpty()) {
        out.insert(QStringLiteral("powered"), objects.value(QDBusObjectPath(adapter)).value(kAdapter).value(QStringLiteral("Powered")).toBool());
        for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
            const QVariantMap d = it.value().value(kDevice1);
            if (d.isEmpty() || !d.value(QStringLiteral("Paired")).toBool())
                continue;
            const QString mac = d.value(QStringLiteral("Address")).toString().toUpper();
            if (!isMac(mac))
                continue;
            QString name = d.value(QStringLiteral("Alias")).toString().trimmed();
            if (name.isEmpty())
                name = d.value(QStringLiteral("Name")).toString().trimmed();
            devices.append(QJsonObject{{QStringLiteral("mac"), mac},
                                       {QStringLiteral("name"), name.isEmpty() ? mac : name},
                                       {QStringLiteral("connected"), d.value(QStringLiteral("Connected")).toBool()}});
        }
    }
    out.insert(QStringLiteral("devices"), devices);
    r.ok = true;
    r.json = out;
    return r;
}

StateResult hostState(BusCaller &bus)
{
    StateResult r;
    const Props p = allProperties(bus, kHostService, kHostPath, kHostService);
    if (!p.ok) {
        r.error = reasonOf(p.error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("pretty"), clean(p.map.value(QStringLiteral("PrettyHostname")))},
                         {QStringLiteral("static"), clean(p.map.value(QStringLiteral("StaticHostname")))},
                         {QStringLiteral("hostname"), clean(p.map.value(QStringLiteral("Hostname")))},
                         {QStringLiteral("chassis"), clean(p.map.value(QStringLiteral("Chassis")))},
                         {QStringLiteral("vendor"), clean(p.map.value(QStringLiteral("HardwareVendor")))},
                         {QStringLiteral("model"), clean(p.map.value(QStringLiteral("HardwareModel")))}};
    r.ok = true;
    return r;
}

StateResult timeState(BusCaller &bus)
{
    StateResult r;
    const Props p = allProperties(bus, kTimeService, kTimePath, kTimeService);
    if (!p.ok) {
        r.error = reasonOf(p.error);
        return r;
    }
    QJsonObject out{{QStringLiteral("zone"), clean(p.map.value(QStringLiteral("Timezone")))},
                    {QStringLiteral("ntp"), unwrap(p.map.value(QStringLiteral("NTP"))).toBool()},
                    {QStringLiteral("canNtp"), unwrap(p.map.value(QStringLiteral("CanNTP"))).toBool()},
                    {QStringLiteral("synced"), unwrap(p.map.value(QStringLiteral("NTPSynchronized"))).toBool()},
                    {QStringLiteral("localRtc"), unwrap(p.map.value(QStringLiteral("LocalRTC"))).toBool()},
                    {QStringLiteral("usec"), QString::number(unwrap(p.map.value(QStringLiteral("TimeUSec"))).toULongLong())}};
    // The time servers, when timesyncd runs (its absence is no error: the source then reads as unknown).
    const Props sync = allProperties(bus, kSyncService, kSyncPath, kSyncManager);
    QStringList servers;
    if (sync.ok) {
        for (const char *key : {"LinkNTPServers", "SystemNTPServers", "FallbackNTPServers"}) {
            for (const QString &server : strings(sync.map.value(QLatin1String(key)))) {
                if (!server.isEmpty() && !servers.contains(server))
                    servers << server;
            }
        }
    }
    out.insert(QStringLiteral("server"), sync.ok ? clean(sync.map.value(QStringLiteral("ServerName"))) : QString());
    out.insert(QStringLiteral("servers"), jsonStrings(servers));
    r.json = out;
    r.ok = true;
    return r;
}

StateResult timeZones(BusCaller &bus)
{
    StateResult r;
    const BusReply reply = bus.call(kTimeService, kTimePath, kTimeService, QStringLiteral("ListTimezones"), {}, kReadMs);
    if (!reply.ok || reply.args.isEmpty()) {
        r.error = reasonOf(reply.ok ? QCoreApplication::translate("SystemBus", "empty reply") : reply.error);
        return r;
    }
    QStringList zones;
    for (const QString &z : strings(reply.args.first())) {
        if (isZone(z))
            zones << z;
    }
    r.json = QJsonObject{{QStringLiteral("zones"), jsonStrings(zones)}};
    r.ok = true;
    return r;
}

StateResult localeState(BusCaller &bus)
{
    StateResult r;
    const Result locale = property(bus, kLocaleService, kLocalePath, kLocaleService, QStringLiteral("Locale"));
    if (!locale.ok) {
        r.error = reasonOf(locale.error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("locale"), jsonStrings(strings(locale.value))}};
    r.ok = true;
    return r;
}

StateResult userUnits(BusCaller &bus, const QStringList &ownDirs)
{
    StateResult r;
    const BusReply reply = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("ListUnitFilesByPatterns"),
                                    {QStringList{QStringLiteral("enabled"), QStringLiteral("disabled")}, QStringList{QStringLiteral("*.service")}}, kReadMs);
    if (!reply.ok || reply.args.isEmpty()) {
        r.error = reasonOf(reply.ok ? QCoreApplication::translate("SystemBus", "empty reply") : reply.error);
        return r;
    }
    QJsonArray units;
    for (const auto &[path, state] : unitFiles(reply.args.first())) {
        bool own = false;
        for (const QString &dir : ownDirs)
            own = own || (!dir.isEmpty() && path.startsWith(dir + QLatin1Char('/')) && !path.mid(dir.size() + 1).contains(QLatin1Char('/')));
        const QString unit = path.section(QLatin1Char('/'), -1);
        if (own && isUserUnit(unit))
            units.append(QJsonObject{{QStringLiteral("unit"), unit}, {QStringLiteral("path"), path}, {QStringLiteral("state"), state}});
    }
    r.json = QJsonObject{{QStringLiteral("units"), units}};
    r.ok = true;
    return r;
}

QString hostNameFor(const QString &name)
{
    QString out;
    for (const QChar c : name.toLower()) {
        if ((c >= QLatin1Char('a') && c <= QLatin1Char('z')) || (c >= QLatin1Char('0') && c <= QLatin1Char('9')))
            out += c;
        else if (!out.isEmpty() && !out.endsWith(QLatin1Char('-')))
            out += QLatin1Char('-');
    }
    while (out.endsWith(QLatin1Char('-')))
        out.chop(1);
    out = out.left(63);
    while (out.endsWith(QLatin1Char('-')))
        out.chop(1);
    return out;
}

bool sessionAction(const QVariantMap &op)
{
    return op.value(QStringLiteral("op")).toString().startsWith(QLatin1String("user."));
}

bool privilegedAction(const QVariantMap &op)
{
    const QString name = op.value(QStringLiteral("op")).toString();
    return name.startsWith(QLatin1String("host.")) || name.startsWith(QLatin1String("time.")) || name == QLatin1String("wifi.forget")
        || name == QLatin1String("wifi.connectOpen") || name == QLatin1String("wifi.connectSecure");
}

bool validAction(const QVariantMap &op)
{
    const QString name = op.value(QStringLiteral("op")).toString();
    if (name == QLatin1String("host.setName"))
        return op.value(QStringLiteral("name")).metaType() == QMetaType::fromType<QString>() && isComputerName(op.value(QStringLiteral("name")).toString());
    if (name == QLatin1String("time.ntp"))
        return isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("time.zone"))
        return op.value(QStringLiteral("zone")).metaType() == QMetaType::fromType<QString>() && isZone(op.value(QStringLiteral("zone")).toString());
    if (name == QLatin1String("time.set"))
        return isUsec(op.value(QStringLiteral("usec")), nullptr);
    if (name == QLatin1String("user.enable"))
        return isUserUnit(op.value(QStringLiteral("unit")).toString()) && isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("wifi.radio") || name == QLatin1String("bt.power"))
        return isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("wifi.connectKnown"))
        return isUuid(op.value(QStringLiteral("uuid")).toString());
    if (name == QLatin1String("wifi.connectOpen"))
        return isSsidHex(op.value(QStringLiteral("hex")).toString());
    if (name == QLatin1String("wifi.disconnect") || name == QLatin1String("wifi.scan"))
        return true;
    if (name == QLatin1String("wifi.connectSecure"))
        return isSsidHex(op.value(QStringLiteral("hex")).toString()) && isPassphrase(op.value(QStringLiteral("psk")));
    if (name == QLatin1String("wifi.forget"))
        return isUuid(op.value(QStringLiteral("uuid")).toString());
    if (name == QLatin1String("vpn.connect"))
        return isUuid(op.value(QStringLiteral("uuid")).toString()) && isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("bt.connect"))
        return isMac(op.value(QStringLiteral("mac")).toString()) && isBool(op.value(QStringLiteral("connect")));
    return false;
}

namespace {
constexpr uint kKeyMgmtPsk = 0x100;
constexpr uint kKeyMgmtSae = 0x400;
constexpr int kJoinPollMs = 250;

// Waits (kActMs at most) for a connection NetworkManager is activating: "" once it is up. A connection that went down or away
// failed (a wrong password: no agent gives NetworkManager another one); its new profile is deleted, so a failed join leaves no
// saved network behind (as nmcli does).
QString awaitJoin(BusCaller &bus, const QString &profile, const QString &active)
{
    for (int waited = 0; waited <= kActMs; waited += kJoinPollMs) {
        const Result state = property(bus, kNmService, active, kNmActive, QStringLiteral("State"));
        const uint value = state.ok ? state.value.toUInt() : 4;
        if (value == 2)
            return QString();
        if (value >= 3)
            break;
        QThread::msleep(kJoinPollMs);
    }
    bus.call(kNmService, profile, kNmConnection, QStringLiteral("Delete"), {}, kActMs);
    return QCoreApplication::translate("SystemBus", "the network could not be joined");
}

// Joins a WPA/WPA2/WPA3 personal network with its passphrase: the strongest access point of that SSID that takes one (PSK or
// SAE), with a new profile of the whole system (NetworkManager may ask polkit, ADR-0026). WPA3-only access points get
// key-mgmt sae, the others wpa-psk (which NetworkManager also uses for WPA2/WPA3 transition). An enterprise (802.1X), WEP or
// open network is not joined this way.
QString joinWithPassphrase(BusCaller &bus, const QString &devicePath, const QByteArray &ssid, const QString &psk)
{
    bool seen = false;
    bool found = false;
    AccessPoint ap;
    for (const AccessPoint &candidate : accessPoints(bus, devicePath)) {
        if (candidate.ssid != ssid)
            continue;
        seen = true;
        if (((candidate.wpa | candidate.rsn) & (kKeyMgmtPsk | kKeyMgmtSae)) != 0 && (!found || candidate.strength > ap.strength)) {
            ap = candidate;
            found = true;
        }
    }
    if (!found)
        return seen ? QCoreApplication::translate("SystemBus", "that network does not take a password") : QCoreApplication::translate("SystemBus", "that network is no longer in range");
    const bool saeOnly = ((ap.wpa | ap.rsn) & kKeyMgmtPsk) == 0;
    ConnectionSettings settings;
    settings.insert(QStringLiteral("connection"), QVariantMap{{QStringLiteral("id"), QString::fromUtf8(ssid)}, {QStringLiteral("type"), QStringLiteral("802-11-wireless")}});
    settings.insert(QStringLiteral("802-11-wireless"), QVariantMap{{QStringLiteral("ssid"), ssid}, {QStringLiteral("mode"), QStringLiteral("infrastructure")}});
    settings.insert(QStringLiteral("802-11-wireless-security"),
                    QVariantMap{{QStringLiteral("key-mgmt"), saeOnly ? QStringLiteral("sae") : QStringLiteral("wpa-psk")}, {QStringLiteral("psk"), psk}}); // i18n-ignore: NetworkManager key-mgmt values
    const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("AddAndActivateConnection"),
                                {QVariant::fromValue(settings), QVariant::fromValue(QDBusObjectPath(devicePath)), QVariant::fromValue(QDBusObjectPath(ap.path))}, kPrivilegedMs);
    if (!r.ok)
        return fail(r.error);
    if (r.args.size() < 2)
        return QString();
    return awaitJoin(bus, cast<QDBusObjectPath>(r.args.value(0)).path(), cast<QDBusObjectPath>(r.args.value(1)).path());
}
} // namespace

QString runAction(BusCaller &bus, const QVariantMap &op, const QStringList &ownDirs)
{
    if (!validAction(op))
        return QCoreApplication::translate("SystemBus", "invalid request");
    const QString name = op.value(QStringLiteral("op")).toString();

    // General (ADR-0026): the service asks the polkit agent (interactive = true) and answers once the user did.
    if (name == QLatin1String("host.setName")) {
        const QString pretty = op.value(QStringLiteral("name")).toString().trimmed();
        const QString error = privileged(bus, kHostService, kHostPath, QStringLiteral("SetPrettyHostname"), {pretty, true});
        if (!error.isEmpty())
            return error;
        const QString host = hostNameFor(pretty);
        return host.isEmpty() ? QString() : privileged(bus, kHostService, kHostPath, QStringLiteral("SetStaticHostname"), {host, true}); // i18n-ignore: a D-Bus method name
    }
    if (name == QLatin1String("time.ntp"))
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetNTP"), {op.value(QStringLiteral("on")).toBool(), true});
    if (name == QLatin1String("time.zone"))
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetTimezone"), {op.value(QStringLiteral("zone")).toString(), true});
    if (name == QLatin1String("time.set")) {
        qint64 usec = 0;
        isUsec(op.value(QStringLiteral("usec")), &usec);
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetTime"), {QVariant::fromValue(usec), false, true});
    }
    if (name == QLatin1String("user.enable")) {
        // Only one of the user's own services (userUnits): never a unit a package or the system ships.
        const QString unit = op.value(QStringLiteral("unit")).toString();
        const StateResult own = userUnits(bus, ownDirs);
        if (!own.ok)
            return own.error;
        bool listed = false;
        for (const QJsonValue &u : own.json.value(QStringLiteral("units")).toArray())
            listed = listed || u.toObject().value(QStringLiteral("unit")).toString() == unit;
        if (!listed)
            return QCoreApplication::translate("SystemBus", "that item is not one of your own");
        const bool on = op.value(QStringLiteral("on")).toBool();
        const BusReply r = on ? bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("EnableUnitFiles"), {QStringList{unit}, false, false}, kActMs)
                              : bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("DisableUnitFiles"), {QStringList{unit}, false}, kActMs);
        if (!r.ok)
            return fail(r.error);
        const BusReply reload = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("Reload"), {}, kActMs);
        return reload.ok ? QString() : fail(reload.error);
    }
    if (name == QLatin1String("wifi.radio"))
        return setProperty(bus, kNmService, kNmPath, kNmIface, QStringLiteral("WirelessEnabled"), op.value(QStringLiteral("on")).toBool());

    // Forget This Network: the saved Wi-Fi profile with that uuid goes. NetworkManager asks polkit itself for a profile of the
    // whole system (settings.modify.system, ADR-0026), so the call waits for the user's answer.
    if (name == QLatin1String("wifi.forget")) {
        const QString uuid = op.value(QStringLiteral("uuid")).toString();
        for (const AnyProfile &p : allProfiles(bus)) {
            if (p.type != QLatin1String("802-11-wireless") || p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                continue;
            const BusReply r = bus.call(kNmService, p.path, kNmConnection, QStringLiteral("Delete"), {}, kPrivilegedMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that network is no longer saved");
    }
    // A VPN or WireGuard profile switched on (activated on no particular device) or off (its active connection deactivated).
    if (name == QLatin1String("vpn.connect")) {
        const QString uuid = op.value(QStringLiteral("uuid")).toString();
        for (const AnyProfile &p : allProfiles(bus)) {
            if ((p.type != QLatin1String("vpn") && p.type != QLatin1String("wireguard")) || p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                continue;
            if (op.value(QStringLiteral("on")).toBool()) {
                const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("ActivateConnection"),
                                            {QVariant::fromValue(QDBusObjectPath(p.path)), QVariant::fromValue(QDBusObjectPath(QStringLiteral("/"))),
                                             QVariant::fromValue(QDBusObjectPath(QStringLiteral("/")))},
                                            kActMs);
                return r.ok ? QString() : fail(r.error);
            }
            const QString activePath = activeConnections(bus).value(p.uuid.toLower()).first;
            if (activePath.isEmpty())
                return QString(); // already off
            const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("DeactivateConnection"),
                                        {QVariant::fromValue(QDBusObjectPath(activePath))}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that VPN is no longer saved");
    }

    if (name.startsWith(QLatin1String("wifi."))) {
        QString error;
        const WifiDevice dev = firstWifiDevice(bus, &error);
        if (!dev.found)
            return error.isEmpty() ? QCoreApplication::translate("SystemBus", "no Wi-Fi adapter") : fail(error);
        if (name == QLatin1String("wifi.scan")) {
            const BusReply r = bus.call(kNmService, dev.path, kNmWireless, QStringLiteral("RequestScan"), {QVariant::fromValue(QVariantMap())}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        if (name == QLatin1String("wifi.disconnect")) {
            const BusReply r = bus.call(kNmService, dev.path, kNmDevice, QStringLiteral("Disconnect"), {}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        if (name == QLatin1String("wifi.connectKnown")) {
            const QString uuid = op.value(QStringLiteral("uuid")).toString();
            for (const Profile &p : wifiProfiles(bus)) {
                if (p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                    continue;
                const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("ActivateConnection"),
                                            {QVariant::fromValue(QDBusObjectPath(p.path)), QVariant::fromValue(QDBusObjectPath(dev.path)),
                                             QVariant::fromValue(QDBusObjectPath(QStringLiteral("/")))},
                                            kActMs);
                return r.ok ? QString() : fail(r.error);
            }
            return QCoreApplication::translate("SystemBus", "that network is no longer saved");
        }
        if (name == QLatin1String("wifi.connectSecure"))
            return joinWithPassphrase(bus, dev.path, QByteArray::fromHex(op.value(QStringLiteral("hex")).toString().toLatin1()),
                                      op.value(QStringLiteral("psk")).toString());
        // wifi.connectOpen: only an access point that needs no password (wifi.connectSecure joins the others).
        // The page asks for the row it shows, a network without a password: an access point with the same SSID that is secured is
        // another row. So the choice is made on the security of the access point: the strongest one that needs no password (open
        // or Enhanced Open); only secured ones: refused.
        const QByteArray ssid = QByteArray::fromHex(op.value(QStringLiteral("hex")).toString().toLatin1());
        bool seen = false;
        AccessPoint ap;
        bool haveOpen = false;
        for (const AccessPoint &candidate : accessPoints(bus, dev.path)) {
            if (candidate.ssid != ssid)
                continue;
            seen = true;
            if (!needsCredentials(candidate) && (!haveOpen || candidate.strength > ap.strength)) {
                ap = candidate;
                haveOpen = true;
            }
        }
        if (seen && !haveOpen)
            return QCoreApplication::translate("SystemBus", "that network needs a password");
        if (haveOpen) {
            ConnectionSettings settings;
            settings.insert(QStringLiteral("connection"), QVariantMap{{QStringLiteral("id"), QString::fromUtf8(ssid)}, {QStringLiteral("type"), QStringLiteral("802-11-wireless")}});
            settings.insert(QStringLiteral("802-11-wireless"), QVariantMap{{QStringLiteral("ssid"), ssid}, {QStringLiteral("mode"), QStringLiteral("infrastructure")}});
            if (isOwe(ap)) // NetworkManager joins an OWE access point only with key-mgmt owe (no secret: there is none)
                settings.insert(QStringLiteral("802-11-wireless-security"), QVariantMap{{QStringLiteral("key-mgmt"), QStringLiteral("owe")}});
            // A new profile of the whole system: NetworkManager may ask polkit (settings.modify.system, ADR-0026).
            const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("AddAndActivateConnection"),
                                        {QVariant::fromValue(settings), QVariant::fromValue(QDBusObjectPath(dev.path)), QVariant::fromValue(QDBusObjectPath(ap.path))}, kPrivilegedMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that network is no longer in range");
    }

    // Bluetooth.
    QString error;
    const ManagedObjects objects = bluezObjects(bus, &error);
    if (!error.isEmpty())
        return fail(error);
    if (name == QLatin1String("bt.power")) {
        const QString adapter = firstAdapterPath(objects);
        return adapter.isEmpty() ? QCoreApplication::translate("SystemBus", "no Bluetooth adapter") : setProperty(bus, kBluez, adapter, kAdapter, QStringLiteral("Powered"), op.value(QStringLiteral("on")).toBool());
    }
    const QString mac = op.value(QStringLiteral("mac")).toString().toUpper();
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        const QVariantMap d = it.value().value(kDevice1);
        if (d.isEmpty() || d.value(QStringLiteral("Address")).toString().toUpper() != mac)
            continue;
        // macOS pairs first: a device that is not paired is refused here (pairing needs an agent, which Settings does not run).
        if (op.value(QStringLiteral("connect")).toBool() && !d.value(QStringLiteral("Paired")).toBool())
            return QCoreApplication::translate("SystemBus", "that device is not paired yet");
        const BusReply r = bus.call(kBluez, it.key().path(), kDevice1, op.value(QStringLiteral("connect")).toBool() ? QStringLiteral("Connect") : QStringLiteral("Disconnect"), {}, kActMs); // i18n-ignore: D-Bus method names
        return r.ok ? QString() : fail(r.error);
    }
    return QCoreApplication::translate("SystemBus", "that device is no longer paired");
}

} // namespace grassfield::settings
