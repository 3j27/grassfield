#pragma once

// grassfield-prompter's NetworkManager secret agent (ADR-0035 D-9, owner decision Q10; step 9c; docs/specs/system-dialogs.md
// section 5, SC8): org.freedesktop.NetworkManager.SecretAgent at /org/freedesktop/NetworkManager/SecretAgent on the bridge's
// own system bus connection (GDBus), its secrets asked through the shell's secret sheet as prompter/1 requests of kind "nm".
//
// - Registration follows the shell: AgentManager.Register("org.grassfield.prompter") while a shell that draws "nm" is
//   connected (setWanted), Unregister when it goes; registered again when NetworkManager comes back on the bus (a
//   restarted NetworkManager has forgotten its agents). Without a shell, NetworkManager has no agent and fails with
//   NoSecrets, as before step 9c. The object itself stays registered on the connection for the bridge's life; a call that
//   reaches it while the agent is not registered gets NoSecrets.
// - Only NetworkManager is answered: each call's sender must be the current owner of org.freedesktop.NetworkManager,
//   asked from the bus (GetNameOwner) when the call arrives; any other caller gets PermissionDenied, and nothing is shown.
// - GetSecrets: NmSecrets.h decides; a request the sheet can draw goes to the shell (the Sink) and is answered once: the
//   secrets on Join, UserCanceled on Cancel, NoSecrets on every other end (the shell gone, a wrong answer from it, the
//   bound of 8 requests, NetworkManager leaving the bus, the answer's time running out). CancelGetSecrets withdraws the
//   matching requests from the shell (shown or queued) and answers them AgentCanceled. SaveSecrets is refused (this agent
//   stores no secret, so NetworkManager asks the next agent instead of believing it saved); DeleteSecrets succeeds (there
//   is nothing here to delete).
// - Nothing secret is logged: the journal gets request ids, settings and securities, refusals and why.

#include "NmSecrets.h"
#include "Peer.h"

#include <gio/gio.h>

#include <QByteArray>
#include <QList>
#include <QString>

#include <cstddef>
#include <memory>

namespace gf::prompter {

    class NmAgent;

    // One pending GetSecrets call.
    struct NmRequest {
        NmAgent*               agent      = nullptr;
        GDBusMethodInvocation* invocation = nullptr; // returned exactly once, when the request ends
        QByteArray             path;                 // the connection's object path
        QByteArray             setting;              // the setting name
        nm::Ask                ask;
        QString                id;           // the shell's request id; empty until the bridge sent it
        guint                  timeout = 0;  // the answer's time (a GLib source)
        bool                   ended   = false;
    };

    class NmAgent {
      public:
        class Sink {
          public:
            virtual ~Sink() = default;
            // Show `request` in the shell: its id when it went to the shell, empty when it cannot (no shell, a shell that
            // does not draw "nm", the bound of 8). The request may end inside this call (the shell lost while sending).
            virtual QString submitNm(NmRequest* request) = 0;
            // The agent ended a request the shell holds (NetworkManager cancelled it or left, its time ran out): the shell
            // is told "cancel", the id released.
            virtual void withdrawNm(const QString& id) = 0;
        };

        NmAgent(GDBusConnection* systemBus, Sink* sink, int answerTimeoutMs = nm::kAnswerTimeoutMs);
        ~NmAgent();

        NmAgent(const NmAgent&)            = delete;
        NmAgent& operator=(const NmAgent&) = delete;

        // Registers the object and follows org.freedesktop.NetworkManager's owner. False with *error set.
        bool start(QString* error);
        // Registered with NetworkManager only while true (a shell that draws "nm" is connected).
        void setWanted(bool wanted);

        // The bridge's answers to a request it holds no more. answer() takes over `securePassword` (gcr secure memory,
        // NUL-terminated, `length` bytes): handed to the reply, or zeroed and freed when the request is gone already.
        void answer(NmRequest* request, char* securePassword, std::size_t length, const QByteArray& identity);
        // Ends the request with `errorName` (nm::kErrorUserCanceled for the user's Cancel, nm::kErrorNoSecrets otherwise).
        void refuse(NmRequest* request, const char* errorName, const QString& why);

        int outstanding() const {
            return static_cast<int>(m_requests.size());
        }

      private:
        using Request = std::shared_ptr<NmRequest>;

        static void     onMethodCall(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* method,
                                     GVariant* parameters, GDBusMethodInvocation* invocation, gpointer self);
        static void     onOwnerChecked(GObject* source, GAsyncResult* result, gpointer data);
        static void     onNmOwnerChanged(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* signal,
                                         GVariant* parameters, gpointer self);
        static void     onNmOwner(GObject* source, GAsyncResult* result, gpointer data);
        static void     onRegisterReply(GObject* source, GAsyncResult* result, gpointer data);
        static gboolean onTimeout(gpointer data);

        void    dispatch(const QString& method, GVariant* parameters, GDBusMethodInvocation* invocation);
        void    getSecrets(GVariant* parameters, GDBusMethodInvocation* invocation);
        void    cancelGetSecrets(GVariant* parameters, GDBusMethodInvocation* invocation);
        void    nmOwnerIs(const QString& owner);
        void    sendRegister();
        void    sendUnregister();
        Request find(NmRequest* request) const; // nullptr when it is not outstanding
        Request take(NmRequest* request);       // out of the list (nullptr when it is not there)
        // Ends `request` with an error; `tellShell`: the shell still holds it and is told "cancel".
        void    endWith(const Request& request, const char* errorName, const QString& why, bool tellShell);
        void    endAll(const char* errorName, const QString& why, bool tellShell);

        GDBusConnection* m_bus = nullptr;
        Sink*            m_sink;
        int              m_timeoutMs;
        GCancellable*    m_cancel   = nullptr; // cancelled in ~NmAgent: no reply handler touches the agent after it
        guint            m_objectId = 0;
        guint            m_ownerSub = 0;
        QString          m_nmOwner; // org.freedesktop.NetworkManager's owner as last seen ("" for none)
        bool             m_wanted       = false;
        bool             m_registerSent = false; // a Register went out since the last Unregister
        quint64          m_generation   = 0;
        QList<Request>   m_requests;
        LogThrottle      m_refusals{10000}; // refused callers: one journal line per 10 s
    };

} // namespace gf::prompter
