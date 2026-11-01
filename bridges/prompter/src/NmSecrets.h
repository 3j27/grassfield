#pragma once

// What grassfield-prompter's NetworkManager secret agent answers (ADR-0035 D-9, owner decision Q10; step 9c,
// docs/specs/system-dialogs.md section 5, SC8): the pure rules, unit-tested in tests/unit/prompter/ without a bus. The bus
// side (registration, the sender check, the pending calls) is NmAgent.h.
//
// NetworkManager 1.58 (introspection org.freedesktop.NetworkManager.SecretAgent.xml and AgentManager.xml; libnm's
// nm-dbus-interface.h and nm-errors.h, read as data): GetSecrets(a{sa{sv}} connection, o path, s setting, as hints,
// u flags) -> a{sa{sv}} secrets. The agent asks the user only when the flags allow interaction (ALLOW_INTERACTION or
// REQUEST_NEW); it stores nothing, so without interaction it has nothing to give (NoSecrets). It asks for:
// - "802-11-wireless-security" of a Wi-Fi connection: key-mgmt "wpa-psk" (WPA/WPA2 Personal) and "sae" (WPA3 Personal)
//   -> "psk"; "none" (WEP) -> "wep-key<wep-tx-keyidx>";
// - "802-1x" of a Wi-Fi connection whose key-mgmt is "wpa-eap", "wpa-eap-suite-b-192" or "ieee8021x" (dynamic WEP), with
//   an EAP method that takes a name and a password (peap, ttls, pwd, fast, leap, md5) -> "password" only. The username
//   ("identity") is not a secret: NetworkManager keeps only secret properties from an agent's reply
//   (nm-settings-connection.c validate_secret_flags -> _nm_connection_for_each_secret(remove_non_secrets), libnm's
//   for_each_secret), so the sheet shows the connection's own username, read-only, and a connection without one is not
//   asked (NetworkManager's verify() requires it for these methods anyway). Changing it would mean editing the connection,
//   which this agent never does (opus review of step 9c, MAJOR; decision 9-33 amended).
// Anything else is NoSecrets without a sheet: VPN settings (NetworkManager shows no VPN dialog itself; an agent such as
// nm-applet runs the plugin's auth dialog, which this one does not), LEAP of 802-11-wireless-security, OWE, wired 802.1X,
// EAP methods that need a certificate's password (tls), and a request for other secrets than a name and a password.
// The SSID shown is the connection's (802-11-wireless "ssid", at most 32 bytes): plain text, flattened, inside the
// sheet's fixed sentence, never in the requester row.

#include <gio/gio.h>

#include <QByteArray>
#include <QString>

#include <cstddef>

namespace gf::prompter::nm {

    inline constexpr char kBusName[]           = "org.freedesktop.NetworkManager";
    inline constexpr char kAgentManagerPath[]  = "/org/freedesktop/NetworkManager/AgentManager";
    inline constexpr char kAgentManagerIface[] = "org.freedesktop.NetworkManager.AgentManager";
    inline constexpr char kAgentPath[]         = "/org/freedesktop/NetworkManager/SecretAgent";
    inline constexpr char kAgentIface[]        = "org.freedesktop.NetworkManager.SecretAgent";
    // AgentManager.Register's identifier (D-9): one agent per identifier and user.
    inline constexpr char kIdentifier[] = "org.grassfield.prompter";

    // NMSecretAgentError as NetworkManager reads it back (libnm: the SecretAgent interface name and the error's nick).
    inline constexpr char kErrorFailed[]           = "org.freedesktop.NetworkManager.SecretAgent.Failed";
    inline constexpr char kErrorPermissionDenied[] = "org.freedesktop.NetworkManager.SecretAgent.PermissionDenied";
    inline constexpr char kErrorUserCanceled[]     = "org.freedesktop.NetworkManager.SecretAgent.UserCanceled";
    inline constexpr char kErrorAgentCanceled[]    = "org.freedesktop.NetworkManager.SecretAgent.AgentCanceled";
    inline constexpr char kErrorNoSecrets[]        = "org.freedesktop.NetworkManager.SecretAgent.NoSecrets";

    // NMSecretAgentGetSecretsFlags (the D-Bus ones; NetworkManager masks its internal bits off before calling).
    inline constexpr guint32 kAllowInteraction = 0x1;
    inline constexpr guint32 kRequestNew       = 0x2;
    inline constexpr guint32 kUserRequested    = 0x4;
    inline constexpr guint32 kWpsPbcActive     = 0x8;

    inline constexpr int         kSsidCap      = 64;   // UTF-16 code units of the SSID shown (an SSID is at most 32 bytes)
    inline constexpr int         kIdentityCap  = 256;  // UTF-16 code units of the connection's username, shown read-only
    // NetworkManager gives up on a GetSecrets call after 120 s (nm-secret-agent.c) and never tells the agent: a request
    // still open after this long is withdrawn from the sheet and answered NoSecrets, so no password typed later is lost.
    inline constexpr int kAnswerTimeoutMs = 110000;

    enum class Security { None, Wpa, Wpa3, Wep, Enterprise };

    // The prompter/1 name of a security ("wpa", "wpa3", "wep", "enterprise"; "" for None).
    QString securityName(Security security);

    struct Ask {
        bool       ask = false; // show the sheet
        QString    why;         // when not: why, for the journal (never a secret, never the SSID)
        Security   security = Security::None;
        QString    ssid;     // flattened, not empty
        QString    identity; // Enterprise: the connection's username, flattened, shown read-only (never answered)
        QByteArray setting;  // the setting the reply fills: "802-11-wireless-security" or "802-1x"
        QByteArray key;      // "psk", "wep-key0".."wep-key3", or "password" for Enterprise
    };

    // The flags allow asking the user (ALLOW_INTERACTION or REQUEST_NEW).
    bool interactionAllowed(guint32 flags);

    // The decision for one GetSecrets call: `connection` of type a{sa{sv}}, `hints` NULL-terminated (may be null).
    Ask evaluate(GVariant* connection, const char* settingName, const char* const* hints, guint32 flags);

    // The GetSecrets reply, (a{sa{sv}}): {setting: {key: password}}, nothing else. It takes over
    // `securePassword` (gcr secure memory, NUL-terminated, `length` bytes of valid UTF-8 without NUL): the reply's string
    // is that buffer itself, zeroed and freed when the reply goes. A floating reference.
    GVariant* secretsReply(const Ask& ask, char* securePassword, std::size_t length);

} // namespace gf::prompter::nm
