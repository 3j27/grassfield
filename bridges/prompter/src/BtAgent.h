#pragma once

// grassfield-prompter's BlueZ pairing agent (ADR-0035 D-11, owner decision Q9; step 10; docs/specs/system-dialogs.md
// section 8, BT1-BT4): org.bluez.Agent1 at bt::kAgentPath on the bridge's own system bus connection (GDBus), each pairing
// step drawn by the shell's secret sheet as a prompter/1 request of kind "bluetooth".
//
// - Registration follows the shell: AgentManager1.RegisterAgent(path, "KeyboardDisplay") then RequestDefaultAgent while a
//   shell that draws "bluetooth" is connected (setWanted), UnregisterAgent when it goes; registered again when bluetoothd
//   comes back on the bus (a restarted bluetoothd has forgotten its agents). Release is answered and changes nothing else. Without a shell bluetoothd has no agent: it
//   makes the adapter non-bondable and refuses every step that needs one (ADR-0035 decision 10-1). The object stays
//   registered on the connection for the bridge's life; a call that reaches it while no shell draws the sheet gets
//   Rejected.
// - Only bluetoothd is answered: each call's sender must be the current owner of org.bluez, asked from the bus
//   (GetNameOwner) when the call arrives; any other caller gets org.bluez.Error.Rejected, and nothing is shown.
// - Every argument is checked (BtPairing.h) before the device's properties are read (asynchronously, from that same owner,
//   GetAll of org.bluez.Device1) to name it; then the request goes to the shell (the Sink). A request is answered once: the
//   PIN or the passkey typed, an empty reply for Connect; org.bluez.Error.Canceled for the user's Cancel of a code or a
//   confirmation; org.bluez.Error.Rejected for Decline, and on every other end (the shell gone or refusing, a wrong answer,
//   the bound of 8 requests, bluetoothd leaving the bus, its Cancel or Release, the answer's time running out).
// - A code shown on the screen (DisplayPinCode, answered at once so that bluetoothd hands the PIN to the controller,
//   device.c:7609-7618; DisplayPasskey, which expects no reply) stays until bluetoothd's Cancel or departure, the device
//   reported paired (PropertiesChanged of its Device1 from bluetoothd), another code for that device, the user's Cancel
//   (which asks bluetoothd to stop the pairing: Device1.CancelPairing), or the answer's time; each DisplayPasskey of the same
//   code updates how many digits were typed (`entered`), sent to the shell without touching the sheet's keyboard.
// - Nothing secret or remote-controlled is logged: the journal gets request ids, modes, addresses, refusals and why.

#include "BtPairing.h"
#include "Peer.h"

#include <gio/gio.h>

#include <QByteArray>
#include <QList>
#include <QString>

#include <cstddef>
#include <memory>

namespace gf::prompter {

    class BtAgent;

    // One pairing step bluetoothd asked for.
    struct BtRequest {
        BtAgent*               agent      = nullptr;
        GDBusMethodInvocation* invocation = nullptr; // a call waiting for its reply; nullptr for a code shown (answered at once)
        QByteArray             path;                 // the device's object path (bt::validDevicePath)
        QByteArray             owner;                // the unique name of the org.bluez owner that asked
        bt::Mode               mode     = bt::Mode::Confirm;
        QString                code;                 // the passkey (6 digits) or the PIN shown; "" otherwise
        int                    entered  = 0;         // DisplayPasskey: digits typed on the device, 0 to 6
        QString                service;              // AuthorizeService: bt::serviceKey
        QString                uuid;                 // AuthorizeService: the UUID, lower case
        bt::DeviceView         device;
        QString                id;           // the shell's request id; empty until the bridge sent it
        guint                  timeout   = 0; // the answer's time (a GLib source)
        guint                  pairedSub = 0; // a code shown: PropertiesChanged of the device
        bool                   ended     = false;
    };

    class BtAgent {
      public:
        class Sink {
          public:
            virtual ~Sink() = default;
            // Show `request` in the shell: its id when it went to the shell, empty when it cannot (no shell, a shell that
            // does not draw "bluetooth", the bound of 8). The request may end inside this call (the shell lost while sending).
            virtual QString submitBt(BtRequest* request) = 0;
            // The agent ended a request the shell holds (bluetoothd cancelled it or left, its time ran out, the device was
            // paired): the shell is told "cancel", the id released.
            virtual void withdrawBt(const QString& id) = 0;
            // The digits typed on the device changed for a code the shell shows.
            virtual void progressBt(const QString& id, int entered) = 0;
        };

        BtAgent(GDBusConnection* systemBus, Sink* sink, int answerTimeoutMs = bt::kAnswerTimeoutMs);
        ~BtAgent();

        BtAgent(const BtAgent&)            = delete;
        BtAgent& operator=(const BtAgent&) = delete;

        // Registers the object and follows org.bluez's owner. False with *error set.
        bool start(QString* error);
        // Registered with bluetoothd only while true (a shell that draws "bluetooth" is connected).
        void setWanted(bool wanted);

        // The bridge's answers to a request it holds no more (the shell answered it).
        // The PIN typed: takes over `securePin` (gcr secure memory, NUL-terminated, `length` bytes, bt::validPin): the reply's
        // string is that buffer itself, zeroed and freed when the reply goes (or now when the request is gone already).
        void answerPin(BtRequest* request, char* securePin, std::size_t length);
        void answerPasskey(BtRequest* request, guint32 passkey);
        // Connect: the empty reply of RequestConfirmation, RequestAuthorization or AuthorizeService.
        void answerYes(BtRequest* request);
        // Ends the request with `errorName` (bt::kErrorCanceled for the user's Cancel, bt::kErrorRejected otherwise).
        void refuse(BtRequest* request, const char* errorName, const QString& why);
        // The user's Cancel of a code shown: the request ends and bluetoothd is asked to stop the pairing it started.
        void cancelDisplay(BtRequest* request);

        int outstanding() const {
            return static_cast<int>(m_requests.size());
        }

      private:
        using Request = std::shared_ptr<BtRequest>;

        static void     onMethodCall(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* method,
                                     GVariant* parameters, GDBusMethodInvocation* invocation, gpointer self);
        static void     onOwnerChecked(GObject* source, GAsyncResult* result, gpointer data);
        static void     onBluezOwnerChanged(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface,
                                            const gchar* signal, GVariant* parameters, gpointer self);
        static void     onBluezOwner(GObject* source, GAsyncResult* result, gpointer data);
        static void     onRegisterReply(GObject* source, GAsyncResult* result, gpointer data);
        static void     onDefaultReply(GObject* source, GAsyncResult* result, gpointer data);
        static void     onDeviceProperties(GObject* source, GAsyncResult* result, gpointer data);
        static void     onDeviceChanged(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface,
                                        const gchar* signal, GVariant* parameters, gpointer self);
        static void     onCancelPairingReply(GObject* source, GAsyncResult* result, gpointer data);
        static gboolean onTimeout(gpointer data);

        void    dispatch(const QString& method, GVariant* parameters, GDBusMethodInvocation* invocation);
        // A new request for `path` (already checked); reads the device's properties, then asks the shell.
        void    begin(bt::Mode mode, const QByteArray& path, const QByteArray& owner, const QString& address, GDBusMethodInvocation* invocation,
                      const QString& code, int entered, const QString& service = QString(), const QString& uuid = QString());
        void    submit(const Request& request);
        void    displayPasskey(const QByteArray& path, const QByteArray& owner, const QString& address, guint32 passkey, guint16 entered);
        void    bluezOwnerIs(const QString& owner);
        void    sendRegister();
        void    sendUnregister();
        Request find(BtRequest* request) const; // nullptr when it is not outstanding
        Request take(BtRequest* request);       // out of the list (nullptr when it is not there)
        // Ends `request` with an error (a call waiting for its reply) or just ends it (a code shown); `tellShell`: the shell
        // still holds it and is told "cancel".
        void    endWith(const Request& request, const char* errorName, const QString& why, bool tellShell);
        void    endAll(const char* errorName, const QString& why, bool tellShell);
        void    finish(const Request& request); // the common part of every end: out of the list, timers and watches gone

        GDBusConnection* m_bus = nullptr;
        Sink*            m_sink;
        int              m_timeoutMs;
        GCancellable*    m_cancel   = nullptr; // cancelled in ~BtAgent: no reply handler touches the agent after it
        guint            m_objectId = 0;
        guint            m_ownerSub = 0;
        QString          m_bluezOwner; // org.bluez's owner as last seen ("" for none)
        bool             m_wanted       = false;
        bool             m_registerSent = false; // a RegisterAgent went out since the last UnregisterAgent
        quint64          m_generation   = 0;
        QList<Request>   m_requests;
        LogThrottle      m_refusals{10000}; // refused callers: one journal line per 10 s
    };

} // namespace gf::prompter
