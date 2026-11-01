#include "NmSecrets.h"

#include "Text.h"

#include <gcr/gcr.h>

#include <cstring>
#include <string.h>

namespace gf::prompter::nm {

    namespace {
        constexpr char kWirelessSecurity[] = "802-11-wireless-security";
        constexpr char kDot1x[]            = "802-1x";

        GVariant* settingOf(GVariant* connection, const char* name) {
            return g_variant_lookup_value(connection, name, G_VARIANT_TYPE("a{sv}"));
        }

        QByteArray stringOf(GVariant* setting, const char* key) {
            const gchar* value = nullptr;
            if (setting && g_variant_lookup(setting, key, "&s", &value))
                return QByteArray(value);
            return {};
        }

        bool listHas(const char* const* list, const char* item) {
            for (const char* const* p = list; p && *p; ++p) {
                if (std::strcmp(*p, item) == 0)
                    return true;
            }
            return false;
        }

        // An EAP method that takes a name and a password (NetworkManager's 802-1x "eap" list).
        bool passwordMethod(const char* method) {
            static const char* const kMethods[] = {"peap", "ttls", "pwd", "fast", "leap", "md5", nullptr};
            return listHas(kMethods, method);
        }

        Ask no(const QString& why) {
            Ask a;
            a.why = why;
            return a;
        }

        void wipeSecure(gpointer data) {
            auto* secret = static_cast<char*>(data);
            explicit_bzero(secret, std::strlen(secret));
            gcr_secure_memory_free(secret);
        }

        struct Settings {
            GVariant* connection = nullptr;
            GVariant* wifi       = nullptr;
            GVariant* security   = nullptr;
            GVariant* dot1x      = nullptr;
            ~Settings() {
                for (GVariant* v : {connection, wifi, security, dot1x}) {
                    if (v)
                        g_variant_unref(v);
                }
            }
        };
    } // namespace

    QString securityName(Security security) {
        switch (security) {
            case Security::Wpa: return QStringLiteral("wpa");
            case Security::Wpa3: return QStringLiteral("wpa3");
            case Security::Wep: return QStringLiteral("wep");
            case Security::Enterprise: return QStringLiteral("enterprise");
            case Security::None: break;
        }
        return {};
    }

    bool interactionAllowed(guint32 flags) {
        return (flags & (kAllowInteraction | kRequestNew)) != 0;
    }

    Ask evaluate(GVariant* connection, const char* settingName, const char* const* hints, guint32 flags) {
        if (!connection || !g_variant_is_of_type(connection, G_VARIANT_TYPE("a{sa{sv}}")))
            return no(QStringLiteral("not a connection"));
        // Without interaction an agent returns what it stored, and this one stores nothing.
        if (!interactionAllowed(flags))
            return no(QStringLiteral("no interaction allowed (flags 0x%1) and no secret stored here").arg(flags, 0, 16));
        const QByteArray setting(settingName ? settingName : "");
        if (setting == "vpn")
            return no(QStringLiteral("VPN secrets are not asked here (no VPN plugin dialog runs)"));
        if (setting != kWirelessSecurity && setting != kDot1x)
            return no(QStringLiteral("secrets of %1 are not asked here").arg(flatten(QString::fromUtf8(setting), 64)));

        Settings s;
        s.connection = settingOf(connection, "connection");
        if (stringOf(s.connection, "type") != "802-11-wireless")
            return no(QStringLiteral("not a Wi-Fi connection"));
        s.wifi            = settingOf(connection, "802-11-wireless");
        GVariant* ssidRaw = s.wifi ? g_variant_lookup_value(s.wifi, "ssid", G_VARIANT_TYPE_BYTESTRING) : nullptr;
        gsize     length  = 0;
        const auto* bytes = ssidRaw ? static_cast<const char*>(g_variant_get_fixed_array(ssidRaw, &length, 1)) : nullptr;
        const QString ssid = bytes && length > 0 && length <= 32 ? flatten(QString::fromUtf8(bytes, static_cast<qsizetype>(length)), kSsidCap) : QString();
        if (ssidRaw)
            g_variant_unref(ssidRaw);
        if (ssid.isEmpty())
            return no(QStringLiteral("no SSID that can be shown"));

        s.security            = settingOf(connection, kWirelessSecurity);
        const QByteArray keyMgmt = stringOf(s.security, "key-mgmt");
        Ask a;
        a.ssid    = ssid;
        a.setting = setting;
        if (setting == kWirelessSecurity) {
            if (keyMgmt == "wpa-psk") {
                a.security = Security::Wpa;
                a.key      = "psk";
            } else if (keyMgmt == "sae") {
                a.security = Security::Wpa3;
                a.key      = "psk";
            } else if (keyMgmt == "none") {
                if (stringOf(s.security, "auth-alg") == "leap")
                    return no(QStringLiteral("LEAP is not asked here"));
                guint32 index = 0;
                if (s.security && g_variant_lookup(s.security, "wep-tx-keyidx", "u", &index) && index > 3)
                    return no(QStringLiteral("a WEP key index out of range"));
                a.security = Security::Wep;
                a.key      = QByteArrayLiteral("wep-key") + QByteArray::number(index);
            } else {
                return no(QStringLiteral("key management %1 has no password asked here").arg(flatten(QString::fromUtf8(keyMgmt), 32)));
            }
        } else {
            if (keyMgmt != "wpa-eap" && keyMgmt != "wpa-eap-suite-b-192" && keyMgmt != "ieee8021x")
                return no(QStringLiteral("802.1X secrets of a network that is not WPA Enterprise"));
            s.dot1x = settingOf(connection, kDot1x);
            const gchar** methods = nullptr;
            bool          usable  = false;
            if (s.dot1x && g_variant_lookup(s.dot1x, "eap", "^a&s", &methods)) {
                for (const gchar** m = methods; m && *m; ++m)
                    usable = usable || passwordMethod(*m);
                g_free(methods);
            }
            if (!usable)
                return no(QStringLiteral("an EAP method that takes no name and password here (a certificate's password is not asked)"));
            // NetworkManager names the secrets it thinks are needed; a request for other ones (a key's password, a PIN)
            // cannot be met with a name and a password.
            if (hints && *hints && !listHas(hints, "password") && !listHas(hints, "identity"))
                return no(QStringLiteral("802.1X secrets other than a name and a password"));
            a.identity = flatten(QString::fromUtf8(stringOf(s.dot1x, "identity")), kIdentityCap);
            // The username is shown, never answered (NetworkManager drops non-secrets from a reply): without one stored
            // with the connection the sheet could only ask for a name that would be thrown away.
            if (a.identity.isEmpty())
                return no(QStringLiteral("no username stored with the connection (an agent's reply cannot set one)"));
            a.security = Security::Enterprise;
            a.key      = "password";
        }
        a.ask = true;
        return a;
    }

    GVariant* secretsReply(const Ask& ask, char* securePassword, std::size_t length) {
        GVariantBuilder inner;
        g_variant_builder_init(&inner, G_VARIANT_TYPE("a{sv}"));
        // No copy of the password in GLib's heap here: the string is the secure buffer, with its NUL.
        GVariant* secret = g_variant_new_from_data(G_VARIANT_TYPE_STRING, securePassword, length + 1, TRUE, wipeSecure, securePassword);
        g_variant_builder_add(&inner, "{sv}", ask.key.constData(), secret);
        GVariantBuilder outer;
        g_variant_builder_init(&outer, G_VARIANT_TYPE("a{sa{sv}}"));
        g_variant_builder_add(&outer, "{s@a{sv}}", ask.setting.constData(), g_variant_builder_end(&inner));
        return g_variant_new("(@a{sa{sv}})", g_variant_builder_end(&outer));
    }

} // namespace gf::prompter::nm
