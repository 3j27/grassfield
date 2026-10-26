// Unit tests of apps/settings/src/systembus.h: the Wi-Fi and Bluetooth logic over D-Bus, against a canned bus (no bus, no
// session, nothing of the machine's network or Bluetooth can be reached from here). What is asserted is what the pages show
// (the state JSON) and exactly which calls an action makes, with which arguments, and which it must never make.
#include <gtest/gtest.h>

#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMap>

#include <algorithm>
#include <functional>

#include "systembus.h"

using namespace grassfield::settings;

namespace
{
using ConnectionSettings = QMap<QString, QVariantMap>;
using ManagedObjects = QMap<QDBusObjectPath, ConnectionSettings>;

struct Call {
    QString service, path, iface, member;
    QVariantList args;
    int timeoutMs = 0;
};

// A bus that answers from a table and remembers every call.
class FakeBus : public BusCaller
{
public:
    std::function<BusReply(const Call &)> handler;
    QList<Call> calls;

    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override
    {
        const Call c{service, path, iface, member, args, timeoutMs};
        calls.append(c);
        return handler ? handler(c) : BusReply{false, {}, QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: nobody")};
    }

    QStringList members() const
    {
        QStringList out;
        for (const Call &c : calls)
            out << c.iface.section(QLatin1Char('.'), -1) + QLatin1Char('.') + c.member;
        return out;
    }
};

BusReply ok(const QVariantList &args = {})
{
    return {true, args, {}};
}

BusReply err(const QString &error)
{
    return {false, {}, error};
}

QVariant path(const QString &p)
{
    return QVariant::fromValue(QDBusObjectPath(p));
}

QVariant paths(const QStringList &list)
{
    QList<QDBusObjectPath> out;
    for (const QString &p : list)
        out.append(QDBusObjectPath(p));
    return QVariant::fromValue(out);
}

QVariant variant(const QVariant &v)
{
    return QVariant::fromValue(QDBusVariant(v));
}

QVariant u8(int v)
{
    return QVariant::fromValue<uchar>(static_cast<uchar>(v));
}

QVariant u32(uint v)
{
    return QVariant::fromValue<uint>(v);
}

const QString kNm = QStringLiteral("/org/freedesktop/NetworkManager");

// A NetworkManager with an Ethernet and a Wi-Fi device, three access points (two of them "Home", the stronger one
// connected), an open "Cafe" and a profile for "Home" and one that is not Wi-Fi.
struct NmFixture {
    bool radio = true;
    uint wifiState = 100;
    QString activeAp = QStringLiteral("/ap/1");
    FakeBus bus;
    QMap<QString, QVariantMap> apProps;

    NmFixture()
    {
        apProps[QStringLiteral("/ap/1")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(71)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x188)}};
        apProps[QStringLiteral("/ap/2")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(40)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x188)}};
        apProps[QStringLiteral("/ap/3")] = {{"Ssid", QByteArray("Cafe")}, {"Strength", u8(55)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
        bus.handler = [this](const Call &c) { return answer(c); };
    }

    BusReply answer(const Call &c)
    {
        const QString m = c.member;
        if (c.iface == QLatin1String("org.freedesktop.DBus.Properties")) {
            const QString target = c.args.value(0).toString();
            if (m == QLatin1String("Get")) {
                const QString name = c.args.value(1).toString();
                if (name == QLatin1String("WirelessEnabled"))
                    return ok({variant(radio)});
                if (name == QLatin1String("ActiveAccessPoint"))
                    return ok({variant(path(activeAp))});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device")) {
                if (c.path == QLatin1String("/dev/eth0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(1)}, {"Interface", QStringLiteral("eth0")}, {"State", u32(100)}})});
                return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(2)}, {"Interface", QStringLiteral("wlan0")}, {"State", u32(wifiState)}})});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.AccessPoint")) {
                if (apProps.contains(c.path))
                    return ok({QVariant::fromValue(apProps.value(c.path))});
                return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownObject: gone"));
            }
            if (m == QLatin1String("Set"))
                return ok();
        }
        if (m == QLatin1String("GetDevices"))
            return ok({paths({QStringLiteral("/dev/eth0"), QStringLiteral("/dev/wlan0")})});
        if (m == QLatin1String("GetAllAccessPoints"))
            return ok({paths({QStringLiteral("/ap/1"), QStringLiteral("/ap/2"), QStringLiteral("/ap/3"), QStringLiteral("/ap/gone")})});
        if (m == QLatin1String("ListConnections"))
            return ok({paths({QStringLiteral("/conn/1"), QStringLiteral("/conn/2")})});
        if (m == QLatin1String("GetSettings")) {
            ConnectionSettings s;
            if (c.path == QLatin1String("/conn/1")) {
                s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-11-wireless")}, {"uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}};
                s[QStringLiteral("802-11-wireless")] = {{"ssid", QByteArray("Home")}};
            } else {
                s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-3-ethernet")}, {"uuid", QStringLiteral("11111111-2222-3333-4444-555555555555")}};
            }
            return ok({QVariant::fromValue(s)});
        }
        if (m == QLatin1String("ActivateConnection") || m == QLatin1String("Disconnect") || m == QLatin1String("RequestScan"))
            return ok();
        if (m == QLatin1String("AddAndActivateConnection"))
            return ok({path(QStringLiteral("/conn/new")), path(QStringLiteral("/active/1"))});
        return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + m);
    }
};

QJsonObject stateOf(const StateResult &r)
{
    return r.json;
}
} // namespace

TEST(SystemBusWifi, StateListsRadioDeviceAccessPointsAndProfiles)
{
    NmFixture f;
    const StateResult r = wifiState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    const QJsonObject j = stateOf(r);
    EXPECT_TRUE(j["radio"].toBool());
    EXPECT_EQ(j["device"]["name"].toString(), QStringLiteral("wlan0"));
    EXPECT_TRUE(j["device"]["connected"].toBool());
    const QJsonArray aps = j["aps"].toArray();
    ASSERT_EQ(aps.size(), 3); // the access point that went away between the two calls is skipped
    EXPECT_EQ(aps[0]["hex"].toString(), QStringLiteral("486F6D65")); // "Home"
    EXPECT_EQ(aps[0]["strength"].toInt(), 71);
    EXPECT_TRUE(aps[0]["active"].toBool());
    EXPECT_FALSE(aps[1]["active"].toBool());
    EXPECT_EQ(aps[0]["rsn"].toInt(), 0x188);
    EXPECT_EQ(aps[2]["hex"].toString(), QStringLiteral("43616665"));  // "Cafe"
    const QJsonArray profiles = j["profiles"].toArray();
    ASSERT_EQ(profiles.size(), 1); // the Ethernet profile is not a Wi-Fi one
    EXPECT_EQ(profiles[0]["uuid"].toString(), QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"));
    EXPECT_EQ(profiles[0]["hex"].toString(), QStringLiteral("486F6D65"));
}

TEST(SystemBusWifi, ReadsOnlyReadMethods)
{
    NmFixture f;
    ASSERT_TRUE(wifiState(f.bus).ok);
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << (c.iface + "." + c.member).toStdString();
}

TEST(SystemBusWifi, RadioOffListsNoAccessPointsAndNoDeviceIsNull)
{
    NmFixture f;
    f.radio = false;
    const StateResult r = wifiState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_FALSE(r.json["radio"].toBool());
    EXPECT_EQ(r.json["aps"].toArray().size(), 0);

    FakeBus none;
    none.handler = [](const Call &c) {
        if (c.member == QLatin1String("Get"))
            return ok({variant(true)});
        if (c.member == QLatin1String("GetDevices"))
            return ok({paths({})});
        return ok({paths({})});
    };
    const StateResult n = wifiState(none);
    ASSERT_TRUE(n.ok);
    EXPECT_TRUE(n.json["device"].isNull());
}

TEST(SystemBusWifi, ANetworkManagerThatIsNotRunningIsAReasonNotAnEmptyList)
{
    FakeBus bus;
    const StateResult r = wifiState(bus);
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, QStringLiteral("the service is not running"));
    bus.handler = [](const Call &) { return err(QStringLiteral("org.freedesktop.DBus.Error.NoReply: Did not receive a reply")); };
    EXPECT_EQ(wifiState(bus).error, QStringLiteral("timed out"));
}

TEST(SystemBusWifi, ActionsMakeExactlyTheirCalls)
{
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.radio"}, {"on", false}}), QString());
        ASSERT_EQ(f.bus.calls.size(), 1);
        const Call &c = f.bus.calls[0];
        EXPECT_EQ(c.member, QStringLiteral("Set"));
        EXPECT_EQ(c.path, kNm);
        EXPECT_EQ(c.args[0].toString(), QStringLiteral("org.freedesktop.NetworkManager"));
        EXPECT_EQ(c.args[1].toString(), QStringLiteral("WirelessEnabled"));
        EXPECT_FALSE(qvariant_cast<QDBusVariant>(c.args[2]).variant().toBool());
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}}), QString());
        const Call c = f.bus.calls.last();
        EXPECT_EQ(c.member, QStringLiteral("ActivateConnection"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[0]).path(), QStringLiteral("/conn/1"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[1]).path(), QStringLiteral("/dev/wlan0"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/"));
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.disconnect"}}), QString());
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Disconnect"));
        EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/dev/wlan0"));
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.scan"}}), QString());
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("RequestScan"));
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "43616665"}}), QString());
        const Call c = f.bus.calls.last();
        ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
        ASSERT_GE(c.args.size(), 3);
        const ConnectionSettings s = qvariant_cast<ConnectionSettings>(c.args[0]);
        EXPECT_EQ(s["connection"]["id"].toString(), QStringLiteral("Cafe"));
        EXPECT_EQ(s["connection"]["type"].toString(), QStringLiteral("802-11-wireless"));
        EXPECT_EQ(s["802-11-wireless"]["ssid"].toByteArray(), QByteArray("Cafe"));
        EXPECT_FALSE(s.contains(QStringLiteral("802-11-wireless-security")));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/3"));
    }
}

TEST(SystemBusWifi, ASecuredOrMissingNetworkIsNotJoinedAndSaysWhy)
{
    NmFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QStringLiteral("that network needs a password"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "4E6F7065"}}), QStringLiteral("that network is no longer in range"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "22222222-2222-2222-2222-222222222222"}}), QStringLiteral("that network is no longer saved"));
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(c.member != QLatin1String("AddAndActivateConnection") && c.member != QLatin1String("ActivateConnection"));
}

TEST(SystemBusWifi, AnOpenAndASecuredNetworkOfTheSameNameAreToldApartBySecurity)
{
    // "Home" is secured on /ap/1 and /ap/2 (listed first); an open "Home" (/ap/gone, the page's open row) is joined by ITS access
    // point, not refused for the secured neighbours; the strongest of several open ones is chosen.
    NmFixture f;
    f.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(20)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
    f.apProps[QStringLiteral("/ap/2")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(60)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QString());
    const Call c = f.bus.calls.last();
    ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
    ASSERT_GE(c.args.size(), 3);
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/2"));
    EXPECT_FALSE(qvariant_cast<ConnectionSettings>(c.args[0]).contains(QStringLiteral("802-11-wireless-security")));
    // Only the secured ones left: refused with the password reason, never joined.
    NmFixture g;
    EXPECT_EQ(runAction(g.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QStringLiteral("that network needs a password"));
}

TEST(SystemBusWifi, ASecuredNetworkIsJoinedWithItsPassphraseAndKeptOnlyOnceUp)
{
    NmFixture f;
    QList<uint> states{1, 1, 2}; // activating twice, then activated
    f.bus.handler = [&f, &states](const Call &c) {
        if (c.member == QLatin1String("Get") && c.path == QLatin1String("/active/1") && c.args.value(1).toString() == QLatin1String("State"))
            return ok({variant(u32(states.isEmpty() ? 2 : states.takeFirst()))});
        return f.answer(c);
    };
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "correct horse"}}), QString());
    const auto add = std::find_if(f.bus.calls.cbegin(), f.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("AddAndActivateConnection"); });
    ASSERT_NE(add, f.bus.calls.cend());
    const ConnectionSettings s = qvariant_cast<ConnectionSettings>(add->args[0]);
    EXPECT_EQ(s["802-11-wireless"]["ssid"].toByteArray(), QByteArray("Home"));
    EXPECT_EQ(s["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("wpa-psk"));
    EXPECT_EQ(s["802-11-wireless-security"]["psk"].toString(), QStringLiteral("correct horse"));
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(add->args[2]).path(), QStringLiteral("/ap/1")); // the stronger "Home"
    EXPECT_EQ(add->timeoutMs, 120000); // a profile of the whole system: NetworkManager may ask polkit
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("Connection.Delete")));
    EXPECT_TRUE(states.isEmpty());
    EXPECT_TRUE(privilegedAction({{"op", "wifi.connectSecure"}}));
    EXPECT_TRUE(privilegedAction({{"op", "wifi.connectOpen"}}));

    // WPA3 only (SAE, no PSK): key-mgmt sae.
    NmFixture w;
    w.apProps[QStringLiteral("/ap/1")][QStringLiteral("RsnFlags")] = u32(0x488);
    w.bus.handler = [&w](const Call &c) {
        if (c.member == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("State"))
            return ok({variant(u32(2))});
        return w.answer(c);
    };
    EXPECT_EQ(runAction(w.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "correct horse"}}), QString());
    const auto sae = std::find_if(w.bus.calls.cbegin(), w.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("AddAndActivateConnection"); });
    ASSERT_NE(sae, w.bus.calls.cend());
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(sae->args[2]).path(), QStringLiteral("/ap/1"));
    EXPECT_EQ(qvariant_cast<ConnectionSettings>(sae->args[0])["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("sae"));
}

TEST(SystemBusWifi, AFailedJoinDeletesItsNewProfileAndSaysSo)
{
    // The connection went down (a wrong password), or went away: the new profile is deleted.
    for (const bool gone : {false, true}) {
        NmFixture f;
        f.bus.handler = [&f, gone](const Call &c) {
            if (c.member == QLatin1String("Get") && c.path == QLatin1String("/active/1") && c.args.value(1).toString() == QLatin1String("State"))
                return gone ? err(QStringLiteral("org.freedesktop.DBus.Error.UnknownObject: gone")) : ok({variant(u32(4))});
            if (c.member == QLatin1String("Delete"))
                return ok();
            return f.answer(c);
        };
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "wrong horse"}}), QStringLiteral("the network could not be joined"));
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Delete"));
        EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/conn/new"));
    }
    // An open network takes no password, a missing one is not joined at all.
    NmFixture o;
    EXPECT_EQ(runAction(o.bus, {{"op", "wifi.connectSecure"}, {"hex", "43616665"}, {"psk", "correct horse"}}), QStringLiteral("that network does not take a password"));
    EXPECT_EQ(runAction(o.bus, {{"op", "wifi.connectSecure"}, {"hex", "4E6F7065"}, {"psk", "correct horse"}}), QStringLiteral("that network is no longer in range"));
    EXPECT_FALSE(o.bus.members().contains(QStringLiteral("NetworkManager.AddAndActivateConnection")));
}

TEST(SystemBusWifi, APassphraseIsEightToSixtyThreePrintableCharactersOrSixtyFourHexDigits)
{
    NmFixture f;
    const QString hex64(64, QLatin1Char('a'));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "12345678"}}));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", QString(63, QLatin1Char('~'))}}));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", hex64}}));
    for (const QVariant &psk : {QVariant(QStringLiteral("1234567")), QVariant(QString(64, QLatin1Char('g'))), QVariant(QString(65, QLatin1Char('a'))),
                                QVariant(QStringLiteral("line\nbreak")), QVariant(QStringLiteral("caf\u00e9 au lait")), QVariant(12345678), QVariant()}) {
        f.bus.calls.clear();
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", psk}}), QStringLiteral("invalid request")) << qPrintable(psk.toString());
        EXPECT_TRUE(f.bus.calls.isEmpty());
    }
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "zz"}, {"psk", "12345678"}}), QStringLiteral("invalid request"));
    GuardedCaller dev(f.bus, true);
    f.bus.calls.clear();
    EXPECT_TRUE(runAction(dev, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "12345678"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("NetworkManager.AddAndActivateConnection")));
}

TEST(SystemBusWifi, EnhancedOpenIsJoinedWithoutAPasswordAndWithKeyMgmtOwe)
{
    // OWE (rsn 0x888: OWE key management, CCMP; the privacy flag is set) needs no password: joined like an open network, but
    // NetworkManager needs key-mgmt owe in the profile. One that also offers SAE or PSK needs a password.
    NmFixture f;
    f.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x888)}};
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QString());
    const Call c = f.bus.calls.last();
    ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
    ASSERT_GE(c.args.size(), 3);
    const ConnectionSettings settings = qvariant_cast<ConnectionSettings>(c.args[0]);
    EXPECT_EQ(settings["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("owe"));
    EXPECT_EQ(settings["802-11-wireless-security"].size(), 1) << "no secret in the profile";
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/gone"));
    // Not OWE alone: needs a password, never joined.
    for (uint rsn : {0x888u | 0x400u, 0x888u | 0x100u, 0x888u | 0x200u}) {
        NmFixture g;
        g.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(rsn)}};
        EXPECT_EQ(runAction(g.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QStringLiteral("that network needs a password")) << rsn;
    }
    // OWE transition (rsn 0x1000 only, with or without the privacy flag): the open side is joined as open, no security section.
    for (uint flags : {0u, 1u}) {
        NmFixture t;
        t.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(flags)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x1000)}};
        EXPECT_EQ(runAction(t.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QString()) << flags;
        const Call tc = t.bus.calls.last();
        ASSERT_EQ(tc.member, QStringLiteral("AddAndActivateConnection"));
        ASSERT_GE(tc.args.size(), 3);
        EXPECT_FALSE(qvariant_cast<ConnectionSettings>(tc.args[0]).contains(QStringLiteral("802-11-wireless-security")));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(tc.args[2]).path(), QStringLiteral("/ap/gone"));
    }
    // A cipher-only RSN element (no key management we know) is still a secured network, as the label says ("WPA").
    NmFixture u;
    u.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x8)}};
    EXPECT_EQ(runAction(u.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QStringLiteral("that network needs a password"));
    // A plain open network has no security section.
    NmFixture h;
    EXPECT_EQ(runAction(h.bus, {{"op", "wifi.connectOpen"}, {"hex", "43616665"}}), QString());
    EXPECT_FALSE(qvariant_cast<ConnectionSettings>(h.bus.calls.last().args[0]).contains(QStringLiteral("802-11-wireless-security")));
}

TEST(SystemBusWifi, AFailedCallGivesTheServicesOwnShortReason)
{
    NmFixture f;
    const auto inner = f.bus.handler;
    f.bus.handler = [inner](const Call &c) {
        if (c.member == QLatin1String("ActivateConnection"))
            return err(QStringLiteral("org.freedesktop.NetworkManager.Device.NotActive: Connection\n activation failed: (3) the secrets were\x01 not provided"));
        if (c.member == QLatin1String("Set"))
            return err(QStringLiteral("org.freedesktop.NetworkManager.PermissionDenied: Not authorized to control networking."));
        return inner(c);
    };
    const QString r = runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}});
    EXPECT_EQ(r, QStringLiteral("Connection activation failed: (3) the secrets were not provided"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.radio"}, {"on", true}}), QStringLiteral("not allowed: the system refused the request"));
}

TEST(SystemBusActions, BadValuesNeverReachTheBus)
{
    FakeBus bus;
    const QList<QVariantMap> bad = {
        {},
        {{"op", "wifi.radio"}},
        {{"op", "wifi.radio"}, {"on", "yes"}},
        {{"op", "wifi.radio"}, {"on", 1}},
        {{"op", "wifi.connectKnown"}, {"uuid", "-x"}},
        {{"op", "wifi.connectKnown"}, {"uuid", "Home"}},
        {{"op", "wifi.connectOpen"}, {"hex", ""}},
        {{"op", "wifi.connectOpen"}, {"hex", "XYZ"}},
        {{"op", "wifi.connectOpen"}, {"hex", QString(66, QLatin1Char('A'))}}, // 33 bytes: no SSID is longer than 32
        {{"op", "bt.power"}, {"on", QVariant()}},
        {{"op", "bt.connect"}, {"mac", "not-a-mac"}, {"connect", true}},
        {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF; ls"}, {"connect", true}},
        {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}},
        {{"op", "wifi.forget"}},
        {{"op", "Properties.Set"}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op));
        EXPECT_EQ(runAction(bus, op), QStringLiteral("invalid request"));
    }
    EXPECT_TRUE(bus.calls.isEmpty());
    EXPECT_TRUE(validAction({{"op", "bt.connect"}, {"mac", "aa:bb:cc:dd:ee:ff"}, {"connect", false}}));
}

namespace
{
ManagedObjects bluez(bool powered = true, bool withAdapter = true)
{
    ManagedObjects o;
    if (withAdapter)
        o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0"))][QStringLiteral("org.bluez.Adapter1")] = {{"Address", QStringLiteral("00:11:22:33:44:55")}, {"Powered", powered}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("aa:bb:cc:dd:ee:ff")}, {"Alias", QStringLiteral("Headphones")}, {"Name", QStringLiteral("WH-1000")}, {"Paired", true}, {"Connected", true}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_11_22_33_44_55_66"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("11:22:33:44:55:66")}, {"Name", QStringLiteral("Mouse")}, {"Paired", true}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_66_66_66_66_66_66"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("66:66:66:66:66:66")}, {"Name", QStringLiteral("Seen only")}, {"Paired", false}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_77_77_77_77_77_77"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("77:77:77:77:77:77")}, {"Paired", true}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_bad"))][QStringLiteral("org.bluez.Device1")] = {{"Address", QStringLiteral("not a mac")}, {"Paired", true}};
    return o;
}

struct BtFixture {
    FakeBus bus;
    ManagedObjects objects = bluez();
    BtFixture()
    {
        bus.handler = [this](const Call &c) {
            if (c.member == QLatin1String("GetManagedObjects"))
                return ok({QVariant::fromValue(objects)});
            if (c.member == QLatin1String("Set") || c.member == QLatin1String("Connect") || c.member == QLatin1String("Disconnect"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + c.member);
        };
    }
};
} // namespace

TEST(SystemBusBluetooth, StateListsThePairedDevicesOnly)
{
    BtFixture f;
    const StateResult r = bluetoothState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.json["present"].toBool());
    EXPECT_TRUE(r.json["powered"].toBool());
    QMap<QString, QString> names;
    QMap<QString, bool> connected;
    for (const QJsonValue v : r.json["devices"].toArray()) {
        names[v["mac"].toString()] = v["name"].toString();
        connected[v["mac"].toString()] = v["connected"].toBool();
    }
    EXPECT_EQ(names.size(), 3); // not the unpaired one, not the one with a bad address
    EXPECT_EQ(names["AA:BB:CC:DD:EE:FF"], QStringLiteral("Headphones")); // the alias wins
    EXPECT_EQ(names["11:22:33:44:55:66"], QStringLiteral("Mouse"));      // else the name
    EXPECT_EQ(names["77:77:77:77:77:77"], QStringLiteral("77:77:77:77:77:77")); // else the address
    EXPECT_TRUE(connected["AA:BB:CC:DD:EE:FF"]);
    EXPECT_FALSE(connected["11:22:33:44:55:66"]);
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args));
}

TEST(SystemBusBluetooth, NoAdapterAndAStoppedServiceAreTold)
{
    BtFixture f;
    f.objects = bluez(true, false);
    const StateResult none = bluetoothState(f.bus);
    ASSERT_TRUE(none.ok);
    EXPECT_FALSE(none.json["present"].toBool());
    EXPECT_EQ(none.json["devices"].toArray().size(), 0);
    FakeBus off;
    const StateResult stopped = bluetoothState(off);
    EXPECT_FALSE(stopped.ok);
    EXPECT_EQ(stopped.error, QStringLiteral("the service is not running"));
}

TEST(SystemBusBluetooth, ActionsMakeExactlyTheirCalls)
{
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.power"}, {"on", false}}), QString());
    Call c = f.bus.calls.last();
    EXPECT_EQ(c.member, QStringLiteral("Set"));
    EXPECT_EQ(c.path, QStringLiteral("/org/bluez/hci0"));
    EXPECT_EQ(c.args[0].toString(), QStringLiteral("org.bluez.Adapter1"));
    EXPECT_EQ(c.args[1].toString(), QStringLiteral("Powered"));
    EXPECT_FALSE(qvariant_cast<QDBusVariant>(c.args[2]).variant().toBool());
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", false}}), QString());
    c = f.bus.calls.last();
    EXPECT_EQ(c.member, QStringLiteral("Disconnect"));
    EXPECT_EQ(c.path, QStringLiteral("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "11:22:33:44:55:66"}, {"connect", true}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Connect"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "01:02:03:04:05:06"}, {"connect", true}}), QStringLiteral("that device is no longer paired"));
    f.objects = bluez(true, false);
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.power"}, {"on", true}}), QStringLiteral("no Bluetooth adapter"));
}

TEST(SystemBusBluetooth, ADeviceThatIsNotPairedIsNeverConnected)
{
    // macOS pairs first; Settings has no pairing agent: a seen-but-unpaired device is refused with a reason, and no Connect is sent.
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "66:66:66:66:66:66"}, {"connect", true}}), QStringLiteral("that device is not paired yet"));
    for (const Call &c : f.bus.calls)
        EXPECT_NE(c.member, QStringLiteral("Connect"));
}

TEST(SystemBusBluetooth, AFailedConnectGivesTheServicesReason)
{
    BtFixture f;
    f.bus.handler = [&f](const Call &c) {
        if (c.member == QLatin1String("GetManagedObjects"))
            return ok({QVariant::fromValue(f.objects)});
        return err(QStringLiteral("org.bluez.Error.Failed: Software caused connection abort"));
    };
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}), QStringLiteral("Software caused connection abort"));
}

TEST(SystemBusGuard, ADevSessionSendsReadsAndNothingElse)
{
    NmFixture f;
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(wifiState(dev).ok);
    const int reads = f.bus.calls.size();
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "wifi.radio"}, {"on", false}},
                                                     {{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}},
                                                     {{"op", "wifi.connectOpen"}, {"hex", "43616665"}},
                                                     {{"op", "wifi.disconnect"}},
                                                     {{"op", "wifi.scan"}}}) {
        const QString reason = runAction(dev, op);
        EXPECT_FALSE(reason.isEmpty()) << op.value("op").toString().toStdString();
    }
    BtFixture b;
    GuardedCaller devBt(b.bus, true);
    EXPECT_TRUE(bluetoothState(devBt).ok);
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "bt.power"}, {"on", false}}, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}})
        EXPECT_FALSE(runAction(devBt, op).isEmpty());
    // Nothing but reads reached either bus.
    for (int i = reads; i < f.bus.calls.size(); ++i)
        EXPECT_TRUE(isReadOnlyCall(f.bus.calls[i].service, f.bus.calls[i].iface, f.bus.calls[i].member, f.bus.calls[i].args)) << f.bus.calls[i].member.toStdString();
    for (const Call &c : b.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
    // A real session passes the actions through.
    NmFixture real;
    GuardedCaller session(real.bus, false);
    EXPECT_EQ(runAction(session, {{"op", "wifi.disconnect"}}), QString());
}

TEST(SystemBusGuard, TheReadOnlyListIsExact)
{
    const QString nm = QStringLiteral("org.freedesktop.NetworkManager");
    const QString props = QStringLiteral("org.freedesktop.DBus.Properties");
    EXPECT_TRUE(isReadOnlyCall(nm, props, QStringLiteral("Get"), {}));
    EXPECT_TRUE(isReadOnlyCall(nm, props, QStringLiteral("GetAll"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, props, QStringLiteral("Set"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, nm, QStringLiteral("ActivateConnection"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, nm, QStringLiteral("AddAndActivateConnection"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Device"), QStringLiteral("Disconnect"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Device.Wireless"), QStringLiteral("RequestScan"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("Delete"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("GetSecrets"), {}));
    EXPECT_TRUE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("GetSettings"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.bluez.Device1"), QStringLiteral("Connect"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.bluez.Adapter1"), QStringLiteral("RemoveDevice"), {}));
    EXPECT_TRUE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.freedesktop.DBus.ObjectManager"), QStringLiteral("GetManagedObjects"), {}));
    // Another service is never a read of ours.
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.login1"), props, QStringLiteral("Get"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.systemd1"), QStringLiteral("org.freedesktop.systemd1.Manager"), QStringLiteral("Reboot"), {}));
}

TEST(SystemBusReason, IsShortOneLineAndPlain)
{
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable")), QStringLiteral("the service is not running"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.NameHasNoOwner: x")), QStringLiteral("the service is not running"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.AccessDenied: no")), QStringLiteral("not allowed: the system refused the request"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.bluez.Error.Failed: line one\nline two")), QStringLiteral("line one line two"));
    EXPECT_LE(reasonOf(QStringLiteral("org.x.Error: ") + QString(500, QLatin1Char('a'))).size(), 160);
    EXPECT_EQ(reasonOf(QString()), QString());
}

// ---- General (PR #4, ADR-0026): hostname1, timedate1 / timesync1, locale1 on the system bus; the user's services on the session bus.

namespace
{
const QString kHost = QStringLiteral("org.freedesktop.hostname1");
const QString kTime = QStringLiteral("org.freedesktop.timedate1");
const QString kSync = QStringLiteral("org.freedesktop.timesync1");
const QString kSystemdName = QStringLiteral("org.freedesktop.systemd1");

// hostname1, timedate1 and timesync1 answering GetAll; every other call succeeds with no value.
struct GeneralFixture {
    FakeBus bus;
    bool timesync = true;
    GeneralFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            if (c.member == QLatin1String("GetAll") && c.service == kHost)
                return ok({QVariantMap{{"PrettyHostname", "Chapdel\x01's Laptop"}, {"StaticHostname", "chapdels-laptop"}, {"Hostname", "chapdels-laptop"},
                                       {"Chassis", "laptop"}, {"HardwareVendor", "LENOVO"}, {"HardwareModel", "ThinkPad X1 Carbon Gen 11"}}});
            if (c.member == QLatin1String("GetAll") && c.service == kTime)
                return ok({QVariantMap{{"Timezone", "Europe/Paris"}, {"NTP", true}, {"CanNTP", true}, {"NTPSynchronized", true}, {"LocalRTC", false},
                                       {"TimeUSec", QVariant::fromValue<qulonglong>(1792832460123456ULL)}}});
            if (c.member == QLatin1String("GetAll") && c.service == kSync)
                return timesync ? ok({QVariantMap{{"LinkNTPServers", QStringList{}}, {"SystemNTPServers", QStringList{"time.example.org"}},
                                                  {"FallbackNTPServers", QStringList{"0.arch.pool.ntp.org", "time.example.org"}}, {"ServerName", "time.example.org"}}})
                                : err(QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: not activatable"));
            if (c.member == QLatin1String("ListTimezones"))
                return ok({QStringList{"Europe/Paris", "America/New_York", "../etc/passwd", "UTC"}});
            if (c.member == QLatin1String("ListUnitFilesByPatterns"))
                // One argument, the a(ss) array (QVariantList{QVariant(...)}: a braced QVariantList alone would be copied, not wrapped).
                return ok(QVariantList{QVariant(QVariantList{QVariantList{"/home/u/.config/systemd/user/sync.service", "enabled"},
                                        QVariantList{"/home/u/.config/systemd/user/backup.service", "disabled"},
                                        QVariantList{"/home/u/.config/systemd/user/sub/x.service", "enabled"},
                                        QVariantList{"/usr/lib/systemd/user/pipewire.service", "enabled"},
                                        QVariantList{"/home/u/.local/share/systemd/user/mine.service", "enabled"}})});
            return ok();
        };
    }
};

const QStringList kOwn{QStringLiteral("/home/u/.config/systemd/user"), QStringLiteral("/home/u/.local/share/systemd/user")};
} // namespace

TEST(SystemBusGeneral, HostStateIsHostname1sNamesAndHardware)
{
    GeneralFixture f;
    const StateResult r = hostState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.json.value("pretty").toString(), QStringLiteral("Chapdel's Laptop")); // the control character is dropped
    EXPECT_EQ(r.json.value("static").toString(), QStringLiteral("chapdels-laptop"));
    EXPECT_EQ(r.json.value("chassis").toString(), QStringLiteral("laptop"));
    EXPECT_EQ(r.json.value("vendor").toString(), QStringLiteral("LENOVO"));
    EXPECT_EQ(r.json.value("model").toString(), QStringLiteral("ThinkPad X1 Carbon Gen 11"));
}

TEST(SystemBusGeneral, RenamingSetsThePrettyThenTheStaticNameInteractively)
{
    GeneralFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "host.setName"}, {"name", QStringLiteral("  Chapdel’s ThinkPad X1  ")}}), QString());
    ASSERT_EQ(f.bus.calls.size(), 2);
    EXPECT_EQ(f.bus.calls[0].member, QStringLiteral("SetPrettyHostname"));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{QStringLiteral("Chapdel’s ThinkPad X1"), true}));
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("SetStaticHostname"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringLiteral("chapdel-s-thinkpad-x1"), true}));
    // A name with nothing usable for a host name sets the pretty name only.
    GeneralFixture g;
    EXPECT_EQ(runAction(g.bus, {{"op", "host.setName"}, {"name", QStringLiteral("☃☃")}}), QString());
    EXPECT_EQ(g.bus.members(), QStringList{QStringLiteral("hostname1.SetPrettyHostname")});
}

TEST(SystemBusGeneral, HostNamesFollowHostname1sRules)
{
    EXPECT_EQ(hostNameFor(QStringLiteral("Grassfield Reference")), QStringLiteral("grassfield-reference"));
    EXPECT_EQ(hostNameFor(QStringLiteral("--Été 2026!!--")), QStringLiteral("t-2026"));
    EXPECT_EQ(hostNameFor(QString(100, QLatin1Char('a'))).size(), 63);
    EXPECT_EQ(hostNameFor(QString(62, QLatin1Char('a')) + QStringLiteral(" b")), QString(62, QLatin1Char('a')));
    EXPECT_EQ(hostNameFor(QStringLiteral("!!!")), QString());
}

TEST(SystemBusGeneral, TimeStateReadsTimedate1AndTheServers)
{
    GeneralFixture f;
    const StateResult r = timeState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.json.value("zone").toString(), QStringLiteral("Europe/Paris"));
    EXPECT_TRUE(r.json.value("ntp").toBool());
    EXPECT_TRUE(r.json.value("synced").toBool());
    EXPECT_EQ(r.json.value("usec").toString(), QStringLiteral("1792832460123456"));
    EXPECT_EQ(r.json.value("server").toString(), QStringLiteral("time.example.org"));
    EXPECT_EQ(r.json.value("servers").toArray().size(), 2); // without duplicates
    // Without timesyncd the time still reads; the source is unknown.
    GeneralFixture g;
    g.timesync = false;
    const StateResult s = timeState(g.bus);
    ASSERT_TRUE(s.ok);
    EXPECT_EQ(s.json.value("servers").toArray().size(), 0);
    // The zone list keeps only zone names.
    const StateResult z = timeZones(f.bus);
    ASSERT_TRUE(z.ok);
    EXPECT_EQ(z.json.value("zones").toArray().size(), 3);
}

TEST(SystemBusGeneral, TimeActionsAreInteractiveTimedate1Calls)
{
    GeneralFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "time.ntp"}, {"on", false}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "time.zone"}, {"zone", "America/New_York"}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "time.set"}, {"usec", "1792832460000000"}}), QString());
    ASSERT_EQ(f.bus.calls.size(), 3);
    EXPECT_EQ(f.bus.calls[0].member, QStringLiteral("SetNTP"));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{false, true}));
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("SetTimezone"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringLiteral("America/New_York"), true}));
    EXPECT_EQ(f.bus.calls[2].member, QStringLiteral("SetTime"));
    EXPECT_EQ(f.bus.calls[2].args, (QVariantList{QVariant::fromValue<qint64>(1792832460000000LL), false, true}));
    for (const Call &c : f.bus.calls)
        EXPECT_EQ(c.service, kTime);
    EXPECT_TRUE(privilegedAction({{"op", "time.zone"}}));
    EXPECT_TRUE(privilegedAction({{"op", "host.setName"}}));
    EXPECT_FALSE(privilegedAction({{"op", "user.enable"}}));
    EXPECT_TRUE(sessionAction({{"op", "user.enable"}}));
    EXPECT_FALSE(sessionAction({{"op", "time.ntp"}}));
}

TEST(SystemBusGeneral, BadValuesNeverReachTheBus)
{
    GeneralFixture f;
    const QList<QVariantMap> bad{
        {{"op", "host.setName"}, {"name", QString()}},
        {{"op", "host.setName"}, {"name", QStringLiteral("   ")}},
        {{"op", "host.setName"}, {"name", QString(65, QLatin1Char('x'))}},
        {{"op", "host.setName"}, {"name", QStringLiteral("two\nlines")}},
        {{"op", "host.setName"}, {"name", 42}},
        {{"op", "time.ntp"}, {"on", "true"}},
        {{"op", "time.zone"}, {"zone", "../../etc/passwd"}},
        {{"op", "time.zone"}, {"zone", "Europe/Paris\n"}},
        {{"op", "time.zone"}, {"zone", QString(65, QLatin1Char('a'))}},
        {{"op", "time.set"}, {"usec", "123"}},
        {{"op", "time.set"}, {"usec", "99999999999999999"}},
        {{"op", "time.set"}, {"usec", QVariant::fromValue<qlonglong>(1792832460000000LL)}},
        {{"op", "time.set"}, {"usec", "1792832460000000; reboot"}},
        {{"op", "user.enable"}, {"unit", "../x.service"}, {"on", true}},
        {{"op", "user.enable"}, {"unit", "x.timer"}, {"on", true}},
        {{"op", "user.enable"}, {"unit", "x.service"}, {"on", 1}},
        {{"op", "user.enable"}, {"unit", "x.service\n"}, {"on", true}},
        {{"op", "time.set"}, {"usec", "1792832460000000\n"}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op)) << op.value("op").toString().toStdString();
        EXPECT_FALSE(runAction(f.bus, op).isEmpty());
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
    // The older shapes are anchored as well: a final newline is not part of a MAC, an SSID or a UUID.
    EXPECT_FALSE(validAction({{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF\n"}, {"connect", true}}));
    EXPECT_FALSE(validAction({{"op", "wifi.connectOpen"}, {"hex", "43616665\n"}}));
    EXPECT_FALSE(validAction({{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n"}}));
    EXPECT_TRUE(validAction({{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}));
}

TEST(SystemBusGeneral, OnlyTheUsersOwnServicesAreListedAndSwitched)
{
    GeneralFixture f;
    const StateResult r = userUnits(f.bus, kOwn);
    ASSERT_TRUE(r.ok);
    QStringList units;
    for (const QJsonValue &u : r.json.value("units").toArray())
        units << u.toObject().value("unit").toString();
    EXPECT_EQ(units, (QStringList{"sync.service", "backup.service", "mine.service"})); // not a package's, not a sub-folder's
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "user.enable"}, {"unit", "backup.service"}, {"on", true}}, kOwn), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{"Manager.ListUnitFilesByPatterns", "Manager.EnableUnitFiles", "Manager.Reload"}));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringList{"backup.service"}, false, false}));
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "user.enable"}, {"unit", "sync.service"}, {"on", false}}, kOwn), QString());
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("DisableUnitFiles"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringList{"sync.service"}, false}));
    // A unit a package ships is never switched, nor one that is not there.
    f.bus.calls.clear();
    EXPECT_FALSE(runAction(f.bus, {{"op", "user.enable"}, {"unit", "pipewire.service"}, {"on", false}}, kOwn).isEmpty());
    EXPECT_FALSE(runAction(f.bus, {{"op", "user.enable"}, {"unit", "x.service"}, {"on", false}}, kOwn).isEmpty());
    EXPECT_EQ(f.bus.members(), (QStringList{"Manager.ListUnitFilesByPatterns", "Manager.ListUnitFilesByPatterns"}));
}

TEST(SystemBusGeneral, ADevSessionReadsButNeverChangesTheSystem)
{
    GeneralFixture f;
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(hostState(dev).ok);
    EXPECT_TRUE(timeState(dev).ok);
    EXPECT_TRUE(timeZones(dev).ok);
    EXPECT_TRUE(userUnits(dev, kOwn).ok);
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "host.setName"}, {"name", "x"}},
                                                     {{"op", "time.ntp"}, {"on", false}},
                                                     {{"op", "time.zone"}, {"zone", "UTC"}},
                                                     {{"op", "time.set"}, {"usec", "1792832460000000"}},
                                                     {{"op", "user.enable"}, {"unit", "sync.service"}, {"on", false}}})
        EXPECT_FALSE(runAction(dev, op, kOwn).isEmpty()) << op.value("op").toString().toStdString();
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
    const QString props = QStringLiteral("org.freedesktop.DBus.Properties");
    EXPECT_FALSE(isReadOnlyCall(kHost, kHost, QStringLiteral("SetStaticHostname"), {}));
    EXPECT_FALSE(isReadOnlyCall(kTime, kTime, QStringLiteral("SetTimezone"), {}));
    EXPECT_FALSE(isReadOnlyCall(kTime, props, QStringLiteral("Set"), {}));
    EXPECT_FALSE(isReadOnlyCall(kSystemdName, QStringLiteral("org.freedesktop.systemd1.Manager"), QStringLiteral("EnableUnitFiles"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.locale1"), QStringLiteral("org.freedesktop.locale1"), QStringLiteral("SetLocale"), {}));
    EXPECT_TRUE(isReadOnlyCall(kTime, kTime, QStringLiteral("ListTimezones"), {}));
}

// ---- Network (the Hardware group): devices with their addresses, VPN profiles, Forget, VPN on and off ----
namespace
{
// A NetworkManager with a connected Wi-Fi device (addresses, router, DNS, bitrate, the access point's frequency), a disconnected
// Ethernet device, a loopback that is not listed, a saved Wi-Fi profile, a WireGuard profile that is up and an OpenVPN one that
// is down.
struct NetFixture {
    FakeBus bus;
    NetFixture()
    {
        bus.handler = [](const Call &c) -> BusReply {
            const QString m = c.member, target = c.args.value(0).toString();
            if (m == QLatin1String("GetDevices"))
                return ok({paths({QStringLiteral("/dev/wlan0"), QStringLiteral("/dev/eth0"), QStringLiteral("/dev/lo")})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device")) {
                if (c.path == QLatin1String("/dev/wlan0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(2)}, {"Interface", QStringLiteral("wlan0")}, {"State", u32(100)},
                                                               {"HwAddress", QStringLiteral("AA:BB:CC:00:11:22")}, {"ActiveConnection", path(QStringLiteral("/active/1"))},
                                                               {"Ip4Config", path(QStringLiteral("/ip4/1"))}, {"Ip6Config", path(QStringLiteral("/ip6/1"))}})});
                if (c.path == QLatin1String("/dev/eth0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(1)}, {"Interface", QStringLiteral("eth0")}, {"State", u32(30)},
                                                               {"HwAddress", QStringLiteral("AA:BB:CC:00:11:33")}, {"ActiveConnection", path(QStringLiteral("/"))}})});
                return ok({QVariantMap{{"DeviceType", u32(32)}, {"Interface", QStringLiteral("lo")}, {"State", u32(100)}}});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.IP4Config"))
                return ok({QVariant::fromValue(QVariantMap{{"AddressData", QVariantList{QVariantMap{{"address", QStringLiteral("192.168.1.42")}, {"prefix", u32(24)}}}},
                                                           {"Gateway", QStringLiteral("192.168.1.1")},
                                                           {"NameserverData", QVariantList{QVariantMap{{"address", QStringLiteral("192.168.1.1")}}, QVariantMap{{"address", QStringLiteral("9.9.9.9")}}}}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.IP6Config"))
                return ok({QVariant::fromValue(QVariantMap{{"AddressData", QVariantList{QVariantMap{{"address", QStringLiteral("fe80::1")}, {"prefix", u32(64)}}}},
                                                           {"Gateway", QString()}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device.Wireless"))
                return ok({QVariant::fromValue(QVariantMap{{"Bitrate", u32(866700)}, {"ActiveAccessPoint", path(QStringLiteral("/ap/1"))}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.AccessPoint"))
                return ok({QVariant::fromValue(QVariantMap{{"Frequency", u32(5180)}, {"Ssid", QByteArray("Home")}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Connection.Active")) {
                if (c.path == QLatin1String("/active/1"))
                    return ok({QVariant::fromValue(QVariantMap{{"Id", QStringLiteral("Home")}, {"Uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}, {"State", u32(2)}})});
                return ok({QVariant::fromValue(QVariantMap{{"Id", QStringLiteral("Office")}, {"Uuid", QStringLiteral("AAAAAAAA-0000-0000-0000-000000000001")}, {"State", u32(2)}})});
            }
            if (m == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("Speed"))
                return ok({variant(u32(1000))});
            // systemd: ufw is not installed, firewalld is (and active).
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.systemd1.Unit")) {
                if (c.path.endsWith(QLatin1String("/ufw_2eservice")))
                    return ok({QVariant::fromValue(QVariantMap{{"LoadState", QStringLiteral("not-found")}, {"ActiveState", QStringLiteral("inactive")}})});
                return ok({QVariant::fromValue(QVariantMap{{"LoadState", QStringLiteral("loaded")}, {"ActiveState", QStringLiteral("active")}})});
            }
            if (m == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("ActiveConnections"))
                return ok({variant(QVariant::fromValue(QList<QDBusObjectPath>{QDBusObjectPath(QStringLiteral("/active/1")), QDBusObjectPath(QStringLiteral("/active/2"))}))});
            if (m == QLatin1String("ListConnections"))
                return ok({paths({QStringLiteral("/conn/1"), QStringLiteral("/conn/2"), QStringLiteral("/conn/3")})});
            if (m == QLatin1String("GetSettings")) {
                ConnectionSettings s;
                if (c.path == QLatin1String("/conn/1"))
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-11-wireless")}, {"uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}, {"id", QStringLiteral("Home")}};
                else if (c.path == QLatin1String("/conn/2"))
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("wireguard")}, {"uuid", QStringLiteral("aaaaaaaa-0000-0000-0000-000000000001")}, {"id", QStringLiteral("Office")}};
                else
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("vpn")}, {"uuid", QStringLiteral("bbbbbbbb-0000-0000-0000-000000000002")}, {"id", QStringLiteral("Travel")}};
                return ok({QVariant::fromValue(s)});
            }
            if (m == QLatin1String("Delete") || m == QLatin1String("ActivateConnection") || m == QLatin1String("DeactivateConnection"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + m);
        };
    }
};
} // namespace

TEST(SystemBusNetwork, StateListsEthernetAndWifiWithTheirAddressesAndTheVpns)
{
    NetFixture f;
    const StateResult r = networkState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    const QJsonArray devices = r.json["devices"].toArray();
    ASSERT_EQ(devices.size(), 2); // not the loopback
    const QJsonObject wifi = devices[0].toObject();
    EXPECT_EQ(wifi["type"].toString(), QStringLiteral("wifi"));
    EXPECT_EQ(wifi["state"].toString(), QStringLiteral("connected"));
    EXPECT_EQ(wifi["mac"].toString(), QStringLiteral("AA:BB:CC:00:11:22"));
    EXPECT_EQ(wifi["connection"].toString(), QStringLiteral("Home"));
    EXPECT_EQ(wifi["ip4"].toArray(), QJsonArray({QStringLiteral("192.168.1.42/24")}));
    EXPECT_EQ(wifi["router"].toString(), QStringLiteral("192.168.1.1"));
    EXPECT_EQ(wifi["dns"].toArray(), QJsonArray({QStringLiteral("192.168.1.1"), QStringLiteral("9.9.9.9")}));
    EXPECT_EQ(wifi["ip6"].toArray(), QJsonArray({QStringLiteral("fe80::1/64")}));
    EXPECT_EQ(wifi["bitrate"].toInt(), 866700);
    EXPECT_EQ(wifi["frequency"].toInt(), 5180);
    EXPECT_EQ(wifi["ssid"].toString(), QStringLiteral("486F6D65"));
    const QJsonObject eth = devices[1].toObject();
    EXPECT_EQ(eth["speed"].toInt(), 1000);
    EXPECT_FALSE(wifi.contains(QStringLiteral("speed")));
    // The firewall systemd has loaded, read through Properties only.
    EXPECT_EQ(r.json["firewall"].toObject()["name"].toString(), QStringLiteral("firewalld"));
    EXPECT_TRUE(r.json["firewall"].toObject()["active"].toBool());
    for (const Call &c : f.bus.calls) {
        if (c.service == QLatin1String("org.freedesktop.systemd1"))
            EXPECT_EQ(c.iface, QStringLiteral("org.freedesktop.DBus.Properties")) << qPrintable(c.member);
    }
    EXPECT_EQ(eth["state"].toString(), QStringLiteral("disconnected"));
    EXPECT_FALSE(eth.contains(QStringLiteral("ip4"))); // no addresses read for a device that is not connected
    const QJsonArray vpns = r.json["vpns"].toArray();
    ASSERT_EQ(vpns.size(), 2);
    EXPECT_EQ(vpns[0]["name"].toString(), QStringLiteral("Office"));
    EXPECT_EQ(vpns[0]["kind"].toString(), QStringLiteral("wireguard"));
    EXPECT_EQ(vpns[0]["state"].toString(), QStringLiteral("connected")); // the active uuid matched case-insensitively
    EXPECT_EQ(vpns[1]["state"].toString(), QStringLiteral("disconnected"));
}

TEST(SystemBusNetwork, ForgetAndVpnActionsMakeExactlyTheirCalls)
{
    NetFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.forget"}, {"uuid", "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Delete"));
    EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/conn/1"));
    // NetworkManager may ask polkit first: the call waits for the dialog, and so does the job.
    EXPECT_EQ(f.bus.calls.last().timeoutMs, 120000);
    EXPECT_TRUE(privilegedAction({{"op", "wifi.forget"}}));
    EXPECT_FALSE(privilegedAction({{"op", "vpn.connect"}}));
    // A VPN uuid is not a Wi-Fi network to forget, and the reverse.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.forget"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}}), QStringLiteral("that network is no longer saved"));
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("Connection.Delete")));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}, {"on", true}}), QStringLiteral("that VPN is no longer saved"));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", true}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("ActivateConnection"));
    EXPECT_EQ(f.bus.calls.last().args.value(0).value<QDBusObjectPath>().path(), QStringLiteral("/conn/3"));
    EXPECT_EQ(f.bus.calls.last().args.value(1).value<QDBusObjectPath>().path(), QStringLiteral("/"));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "aaaaaaaa-0000-0000-0000-000000000001"}, {"on", false}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("DeactivateConnection"));
    EXPECT_EQ(f.bus.calls.last().args.value(0).value<QDBusObjectPath>().path(), QStringLiteral("/active/2"));
    // A VPN that is already off: nothing is deactivated.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", false}}), QString());
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("NetworkManager.DeactivateConnection")));
}

TEST(SystemBusNetwork, BadValuesNeverReachTheBusAndADevSessionOnlyReads)
{
    NetFixture f;
    for (const QVariantMap &op : {QVariantMap{{"op", "wifi.forget"}, {"uuid", "not-a-uuid"}}, QVariantMap{{"op", "wifi.forget"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n"}},
                                  QVariantMap{{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", "yes"}},
                                  QVariantMap{{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}}}) {
        f.bus.calls.clear();
        EXPECT_EQ(runAction(f.bus, op), QStringLiteral("invalid request"));
        EXPECT_TRUE(f.bus.calls.isEmpty());
    }
    GuardedCaller dev(f.bus, true);
    f.bus.calls.clear();
    EXPECT_TRUE(networkState(dev).ok);
    EXPECT_TRUE(runAction(dev, {{"op", "wifi.forget"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_TRUE(runAction(dev, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", true}}).startsWith(QStringLiteral("dev guard")));
    for (const QString &m : f.bus.members())
        EXPECT_FALSE(m.endsWith(QLatin1String(".Delete")) || m.endsWith(QLatin1String("ActivateConnection"))) << qPrintable(m);
}
