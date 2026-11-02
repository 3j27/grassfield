#pragma once

// What grassfield-prompter's BlueZ pairing agent shows and accepts (ADR-0035 D-11, owner decision Q9; step 10,
// docs/specs/system-dialogs.md section 8, BT1-BT4): the pure rules, unit-tested in tests/unit/prompter/ without a bus. The bus
// side (registration, the sender check, the pending calls, the device's properties) is BtAgent.h.
//
// BlueZ 5.87 (doc/org.bluez.Agent.rst, doc/org.bluez.AgentManager.rst, src/agent.c, src/device.c, src/adapter.c; read as
// data): bluetoothd calls the default agent's org.bluez.Agent1 methods with the device's object path
// (/org/bluez/hci<N>/dev_XX_XX_XX_XX_XX_XX, built from its address by device.c) and waits 60 s for a reply (agent.c:40,
// REQUEST_TIMEOUT). Every argument is checked here before anything reaches the shell:
// - a device path of exactly that form, under /org/bluez (the address shown is the path's);
// - a passkey (RequestConfirmation, DisplayPasskey) of 0 to 999999, shown as 6 digits with leading zeros (the doc's rule);
// - a PIN to display (DisplayPinCode; plugins/autopair.c makes a random "%06u" for keyboards) of 1 to 16 ASCII letters and
//   digits;
// - a service UUID (AuthorizeService) in its canonical 8-4-4-4-12 hexadecimal form, named by a fixed key when it is a
//   profile of the Bluetooth base UUID that the sheet can name, else "other";
// - the user's answers: a PIN (RequestPinCode) of 1 to 16 ASCII letters and digits (BlueZ refuses a reply outside 1 to 16
//   bytes, agent.c:491-500; the doc: "can be alphanumeric"), a passkey (RequestPasskey) of exactly 6 digits.
// The device is named by its Alias from org.bluez.Device1 (a remote device chooses its own name: plain text, flattened,
// capped, shown only as a quoted field of Grassfield's sentence), else its Name, else its address; its Icon only as one of
// a fixed list of keys.

#include <gio/gio.h>

#include <QString>

#include <cstddef>

namespace gf::prompter::bt {

    inline constexpr char kBusName[]           = "org.bluez";
    inline constexpr char kAgentManagerPath[]  = "/org/bluez";
    inline constexpr char kAgentManagerIface[] = "org.bluez.AgentManager1";
    inline constexpr char kAgentIface[]        = "org.bluez.Agent1";
    inline constexpr char kDeviceIface[]       = "org.bluez.Device1";
    // The agent's object (freely definable, org.bluez.Agent.rst).
    inline constexpr char kAgentPath[] = "/org/grassfield/prompter/BluetoothAgent";
    // A keyboard and a screen: every pairing method can be shown (ADR-0035 D-11).
    inline constexpr char kCapability[] = "KeyboardDisplay";

    // The errors bluetoothd reads back (org.bluez.Agent.rst "Possible errors").
    inline constexpr char kErrorRejected[] = "org.bluez.Error.Rejected";
    inline constexpr char kErrorCanceled[] = "org.bluez.Error.Canceled";

    // bluetoothd stops waiting after 60 s (agent.c:40) and, for a PIN or a passkey, never says so (pincode_reply and
    // passkey_reply have no time-out branch, agent.c:455-512, 570-610): a request still open after this long is withdrawn
    // from the sheet and answered Rejected, so nothing typed later is lost silently. A code shown on the screen
    // (DisplayPasskey, DisplayPinCode) is withdrawn after the same time at the latest: bluetoothd sends no Cancel for it once
    // the call has no reply pending (agent_cancel needs agent->request, agent.c:307-321); it goes sooner when the device is
    // paired, disconnects or is removed, or another code is shown (BtAgent.h; ADR-0035 decision 10-16).
    inline constexpr int kAnswerTimeoutMs = 55000;

    inline constexpr int kNameCap = 64; // UTF-16 code units of the device's name (a Bluetooth name is at most 248 bytes)
    inline constexpr int kDigits  = 6;  // a passkey's digits, and the most "entered" says

    enum class Mode { Pin, Passkey, DisplayPin, DisplayPasskey, Confirm, Authorize, AuthorizeService };

    // The prompter/1 name of a mode: "pin", "passkey", "display-pin", "display-passkey", "confirm", "authorize",
    // "authorize-service".
    QString modeName(Mode mode);
    // The sheet shows a code and has only Cancel (DisplayPinCode, DisplayPasskey): nothing is answered from it.
    bool isDisplay(Mode mode);
    // The sheet asks for a code (RequestPinCode, RequestPasskey).
    bool asksCode(Mode mode);

    // A device's object path as bluetoothd builds it (/org/bluez/hci<0-999>/dev_XX_XX_XX_XX_XX_XX, upper-case hexadecimal);
    // its address ("XX:XX:XX:XX:XX:XX") in *address. False for anything else.
    bool validDevicePath(const char* path, QString* address);

    // A passkey as the sheet shows it: 6 digits with leading zeros; "" when it is over 999999.
    QString formatPasskey(guint32 passkey);

    // 1 to 16 ASCII letters and digits (a PIN to display, or the PIN the user typed).
    bool validPin(const char* text, std::size_t length);

    // The passkey the user typed: exactly 6 ASCII digits. False otherwise.
    bool parsePasskey(const char* text, std::size_t length, guint32* passkey);

    // A service UUID: its fixed key ("audio", "remote-control", "headset", "hands-free", "file-transfer", "object-push",
    // "network", "input", "phonebook", "messages", "serial", "dial-up", or "other"), "" when the text is not a canonical
    // UUID; *canonical gets it in lower case.
    QString serviceKey(const char* uuid, QString* canonical);

    // bluetoothd's Icon property (a freedesktop icon name, src/dbus-common.c class_to_icon and gap_appearance_to_icon) as
    // one of the sheet's keys, each the name of a Grassfield glyph: "keyboard", "mouse", "gamecontroller", "headphones",
    // "speaker", "phone", "laptop", "display", "printer", "camera", or "" (the Bluetooth glyph).
    QString iconKey(const QString& icon);

    struct DeviceView {
        QString name;    // flattened, not empty
        QString address; // XX:XX:XX:XX:XX:XX, the path's
        QString icon;    // iconKey()
    };

    // The device as the sheet names it, from its org.bluez.Device1 properties (`properties` a{sv} or nullptr when they
    // could not be read): Alias, else Name, else the address; an Address property that is not the path's is ignored.
    DeviceView deviceView(GVariant* properties, const QString& pathAddress);

} // namespace gf::prompter::bt
