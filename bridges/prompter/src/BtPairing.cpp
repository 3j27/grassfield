#include "BtPairing.h"

#include "Text.h"

#include <cstring>

namespace gf::prompter::bt {

    namespace {
        bool isHexUpper(char c) {
            return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
        }

        bool isHex(char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        bool isAlnum(char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        // The profiles of the Bluetooth base UUID (0000XXXX-0000-1000-8000-00805f9b34fb) the sheet names, by their 16-bit
        // number (Bluetooth SIG Assigned Numbers, "Service Class and Profile UUIDs"; BlueZ's lib/uuid.h).
        QString profileKey(unsigned short id) {
            switch (id) {
                case 0x110A: // A2DP Source
                case 0x110B: // A2DP Sink
                case 0x110D: // Advanced Audio Distribution
                    return QStringLiteral("audio");
                case 0x110C: // AVRCP Target
                case 0x110E: // AVRCP
                case 0x110F: // AVRCP Controller
                    return QStringLiteral("remote-control");
                case 0x1108: // Headset
                case 0x1112: // Headset Audio Gateway
                case 0x1131: // Headset HS
                    return QStringLiteral("headset");
                case 0x111E: // Hands-Free
                case 0x111F: // Hands-Free Audio Gateway
                    return QStringLiteral("hands-free");
                case 0x1106: // OBEX File Transfer
                    return QStringLiteral("file-transfer");
                case 0x1105: // OBEX Object Push
                    return QStringLiteral("object-push");
                case 0x1115: // PAN User
                case 0x1116: // Network Access Point
                case 0x1117: // Group Network
                    return QStringLiteral("network");
                case 0x1124: // Human Interface Device
                case 0x1812: // HID over GATT
                    return QStringLiteral("input");
                case 0x112E: // Phonebook Access Client
                case 0x112F: // Phonebook Access Server
                case 0x1130: // Phonebook Access
                    return QStringLiteral("phonebook");
                case 0x1132: // Message Access Server
                case 0x1133: // Message Notification Server
                case 0x1134: // Message Access Profile
                    return QStringLiteral("messages");
                case 0x1101: // Serial Port
                    return QStringLiteral("serial");
                case 0x1103: // Dial-up Networking
                    return QStringLiteral("dial-up");
                default: return QStringLiteral("other");
            }
        }

        QString lookupString(GVariant* properties, const char* key) {
            if (!properties || !g_variant_is_of_type(properties, G_VARIANT_TYPE("a{sv}")))
                return {};
            const gchar* value = nullptr;
            if (!g_variant_lookup(properties, key, "&s", &value) || !value)
                return {};
            return flattenUtf8(value, kNameCap);
        }
    } // namespace

    QString modeName(Mode mode) {
        switch (mode) {
            case Mode::Pin: return QStringLiteral("pin");
            case Mode::Passkey: return QStringLiteral("passkey");
            case Mode::DisplayPin: return QStringLiteral("display-pin");
            case Mode::DisplayPasskey: return QStringLiteral("display-passkey");
            case Mode::Confirm: return QStringLiteral("confirm");
            case Mode::Authorize: return QStringLiteral("authorize");
            case Mode::AuthorizeService: return QStringLiteral("authorize-service");
        }
        return {};
    }

    bool isDisplay(Mode mode) {
        return mode == Mode::DisplayPin || mode == Mode::DisplayPasskey;
    }

    bool asksCode(Mode mode) {
        return mode == Mode::Pin || mode == Mode::Passkey;
    }

    bool validDevicePath(const char* path, QString* address) {
        if (!path)
            return false;
        constexpr char head[] = "/org/bluez/hci";
        const std::size_t n   = std::strlen(path);
        if (n < sizeof(head) - 1 || std::strncmp(path, head, sizeof(head) - 1) != 0)
            return false;
        std::size_t i      = sizeof(head) - 1;
        std::size_t digits = 0;
        while (i < n && path[i] >= '0' && path[i] <= '9' && digits < 4) {
            ++i;
            ++digits;
        }
        if (digits == 0 || digits > 3 || (digits > 1 && path[sizeof(head) - 1] == '0'))
            return false;
        constexpr char dev[] = "/dev_";
        if (n - i != (sizeof(dev) - 1) + 17 || std::strncmp(path + i, dev, sizeof(dev) - 1) != 0)
            return false;
        i += sizeof(dev) - 1;
        QString out;
        for (int byte = 0; byte < 6; ++byte) {
            if (!isHexUpper(path[i]) || !isHexUpper(path[i + 1]))
                return false;
            if (byte > 0)
                out.append(u':');
            out.append(QLatin1Char(path[i])).append(QLatin1Char(path[i + 1]));
            i += 2;
            if (byte < 5) {
                if (path[i] != '_')
                    return false;
                ++i;
            }
        }
        if (i != n)
            return false;
        if (address)
            *address = out;
        return true;
    }

    QString formatPasskey(guint32 passkey) {
        if (passkey > 999999)
            return {};
        return QStringLiteral("%1").arg(passkey, kDigits, 10, QLatin1Char('0'));
    }

    bool validPin(const char* text, std::size_t length) {
        if (!text || length < 1 || length > 16)
            return false;
        for (std::size_t i = 0; i < length; ++i) {
            if (!isAlnum(text[i]))
                return false;
        }
        return true;
    }

    bool parsePasskey(const char* text, std::size_t length, guint32* passkey) {
        if (!text || length != static_cast<std::size_t>(kDigits))
            return false;
        guint32 value = 0;
        for (std::size_t i = 0; i < length; ++i) {
            if (text[i] < '0' || text[i] > '9')
                return false;
            value = value * 10 + static_cast<guint32>(text[i] - '0');
        }
        if (passkey)
            *passkey = value;
        return true;
    }

    QString serviceKey(const char* uuid, QString* canonical) {
        if (!uuid || std::strlen(uuid) != 36)
            return {};
        for (int i = 0; i < 36; ++i) {
            const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
            if (dash ? uuid[i] != '-' : !isHex(uuid[i]))
                return {};
        }
        const QString lower = QString::fromLatin1(uuid, 36).toLower();
        if (canonical)
            *canonical = lower;
        if (lower.startsWith(QLatin1String("0000")) && lower.mid(8) == QLatin1String("-0000-1000-8000-00805f9b34fb"))
            return profileKey(static_cast<unsigned short>(lower.mid(4, 4).toUShort(nullptr, 16)));
        return QStringLiteral("other");
    }

    QString iconKey(const QString& icon) {
        if (icon == QLatin1String("input-keyboard"))
            return QStringLiteral("keyboard");
        if (icon == QLatin1String("input-mouse") || icon == QLatin1String("input-tablet"))
            return QStringLiteral("mouse");
        if (icon == QLatin1String("input-gaming"))
            return QStringLiteral("gamecontroller");
        if (icon == QLatin1String("audio-headset") || icon == QLatin1String("audio-headphones"))
            return QStringLiteral("headphones");
        if (icon == QLatin1String("audio-card"))
            return QStringLiteral("speaker");
        if (icon == QLatin1String("phone"))
            return QStringLiteral("phone");
        if (icon == QLatin1String("computer"))
            return QStringLiteral("laptop");
        if (icon == QLatin1String("video-display"))
            return QStringLiteral("display");
        if (icon == QLatin1String("printer"))
            return QStringLiteral("printer");
        if (icon == QLatin1String("camera-photo") || icon == QLatin1String("camera-video"))
            return QStringLiteral("camera");
        return {};
    }

    DeviceView deviceView(GVariant* properties, const QString& pathAddress) {
        DeviceView view;
        view.address = pathAddress;
        // An Address property that is not the path's says nothing the path does not: the path is what bluetoothd built.
        const QString alias = lookupString(properties, "Alias");
        const QString name  = lookupString(properties, "Name");
        view.name           = !alias.isEmpty() ? alias : !name.isEmpty() ? name : pathAddress;
        if (properties && g_variant_is_of_type(properties, G_VARIANT_TYPE("a{sv}"))) {
            const gchar* icon = nullptr;
            if (g_variant_lookup(properties, "Icon", "&s", &icon) && icon)
                view.icon = iconKey(QString::fromUtf8(icon));
        }
        return view;
    }

} // namespace gf::prompter::bt
