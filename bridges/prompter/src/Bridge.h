#pragma once

// grassfield-prompter's core (ADR-0035 D-9, docs/specs/system-dialogs.md section 5): gcr's system prompter on one side, the shell
// on the other.
//
// - libgcr's GcrSystemPrompter (mode MULTIPLE: every caller gets its prompt at once, the shell's one queue orders them) is
//   registered on the bridge's own bus connection at /org/gnome/keyring/Prompter for the bridge's whole life; it runs gcr's
//   protocol (BeginPrompting, PerformPrompt, StopPrompting, the PromptReady/PromptDone callbacks) and the sx-aes-1 exchange.
//   Its prompts are GfPrompt objects (Prompt.h) whose sink is this bridge.
// - The well-known name org.gnome.keyring.SystemPrompter is requested only while a shell is connected and has said hello,
//   without ALLOW_REPLACEMENT (no process can take it away) and queued behind an owner that holds it already (the stock
//   gcr-prompter frees it 10 s after its last prompt); it is released when the shell goes, so the stock prompter is
//   activated for the next prompt, as today. A request that reaches the bridge with no shell is answered "cancelled".
// - The shell connects to a private socket (Peer.h: this user, the expected unit's cgroup) and speaks prompter/1
//   (Protocol.h). One shell at a time.
// - Each request is identified (Identity.h) before the shell sees it; at most limits::kRequests are outstanding, the next
//   ones are answered "cancelled"; a request its caller withdraws is withdrawn from the shell ("cancel"). At most
//   limits::kPrompts gcr prompts are open, at most limits::kPromptsPerCaller of them for one bus connection (Filter.h).
// - Fail closed: no password is ever invented. An answer to an id that is not outstanding is ignored; a wrong answer to an
//   outstanding id cancels that request; a line that cannot be attributed (not JSON, over the length limit, no id) closes
//   the connection, which cancels every request and releases the name.
// - Nothing the callers or the shell send is logged; the journal gets ids, kinds, requesters' roles and paths, and refusals.

#include "Filter.h"
#include "Peer.h"
#include "Prompt.h"
#include "Protocol.h"
#include "Requests.h"

#include <gio/gio.h>

#include <QByteArray>
#include <QHash>
#include <QSet>
#include <QString>
#include <QStringList>

#include <string_view>
#include <sys/types.h>

class QSocketNotifier;

namespace gf::prompter {

    class Bridge : public PromptSink {
      public:
        struct Options {
            QString socketPath;
            QString peerUnit;            // the shell's unit (cgroup leaf)
            bool    requireUserManager = true; // false only in a development run
            uid_t   uid = 0;
        };

        Bridge(GDBusConnection* bus, Options options);
        ~Bridge() override;

        Bridge(const Bridge&)            = delete;
        Bridge& operator=(const Bridge&) = delete;

        // Installs the bus filter, registers gcr's prompter, listens on the socket. False with *error set.
        bool start(QString* error);
        // Releases the name, drops the shell (every request cancelled), closes and removes the socket.
        void stop();

        // PromptSink
        void submit(GfPrompt* prompt) override;
        void withdraw(GfPrompt* prompt) override;
        void forget(GfPrompt* prompt) override;

      private:
        struct Pending {
            GfPrompt*  prompt = nullptr; // a reference, held while outstanding
            PromptKind kind   = PromptKind::None;
            bool       sent   = false;   // the shell has it
            bool       choice = false;   // it was shown with a check box
        };

        static GcrPrompt* onNewPrompt(GcrSystemPrompter* prompter, gpointer self);
        static void       onCredentials(GObject* source, GAsyncResult* result, gpointer data);
        static void       onNameReply(GObject* source, GAsyncResult* result, gpointer data);
        static void       onOwnerReply(GObject* source, GAsyncResult* result, gpointer data);
        static void       onOwnerCredentials(GObject* source, GAsyncResult* result, gpointer data);
        static void       onNameSignal(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* signal,
                                       GVariant* parameters, gpointer self);

        bool listen(QString* error);
        void onAcceptReady();
        void onClientReadable();
        void flush();
        void dropClient(const QString& why);
        void send(const QByteArray& line);
        void handleLine(std::string_view line);
        void protocolError(const QString& code, const QString& why, bool fatal);
        void onAnswer(const ShellLine& answer, std::string_view line);

        void identified(const QString& id, GfPrompt* prompt, const RequesterView& requester);
        void cancelRequest(const QString& id, bool tellShell);
        void cancelAll(bool tellShell);

        void wantName(bool want);
        void refreshName();
        void setNameState(const QString& state, const QString& owner = QString());

        GDBusConnection*   m_bus = nullptr;
        Options            m_options;
        GcrSystemPrompter* m_prompter = nullptr;
        guint              m_filterId = 0;
        FilterState*       m_filterState = nullptr; // the worker thread's; never freed while the connection lives
        guint              m_acquiredSub = 0;
        guint              m_lostSub     = 0;
        guint              m_ownersSub   = 0; // every NameOwnerChanged, so that the filter sees callers leave

        int              m_listenFd = -1;
        LogThrottle      m_refusals{10000}; // one journal line per 10 s for refused connections
        dev_t            m_socketDev = 0;
        ino_t            m_socketIno = 0;
        QSocketNotifier* m_acceptNotifier = nullptr;

        int              m_client = -1;
        QSocketNotifier* m_readNotifier  = nullptr;
        QSocketNotifier* m_writeNotifier = nullptr;
        char*            m_in    = nullptr; // gcr secure memory: what the shell sent, wiped line by line
        std::size_t      m_inLen = 0;
        QByteArray       m_out;
        bool             m_ready    = false; // the shell said hello
        QStringList      m_kinds;           // the kinds it draws
        int              m_badLines = 0;

        RequestBook             m_book{limits::kRequests};
        QHash<QString, Pending> m_pending; // id -> request
        QSet<GfPrompt*>         m_prompts; // live prompts reporting here

        bool    m_nameWanted = false;
        quint64 m_nameGen    = 0;
        QString m_nameState  = QStringLiteral("released");
    };

} // namespace gf::prompter
