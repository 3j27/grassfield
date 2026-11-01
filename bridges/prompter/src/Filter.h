#pragma once

// How the bridge learns who performs a gcr prompt (ADR-0035 decision 9-1). libgcr's GcrSystemPrompter runs the protocol
// and the exchange, and creates the GcrPrompt object without telling it which caller it serves. Before any incoming
// message is dispatched, a filter on the bridge's bus connection rewrites the PerformPrompt calls addressed to the
// prompter object: their properties keep only GcrPrompt's own, with the right types and bounded strings, and the private
// property "grassfield-caller" is set to the message's sender, which the bus daemon writes and no client can choose. gcr
// then sets those properties on the caller's prompt (prompt_update_properties) right before it asks the prompt for a
// password or a confirmation, so the prompt knows its caller from the bus header alone. A PerformPrompt of another shape
// never reaches gcr: its caller gets an InvalidArgs error (security review of step 9a, NIT-3).
//
// The same filter keeps the count of the prompts each connection holds open in gcr (NIT-2): beyond
// limits::kPromptsPerCaller a BeginPrompting is answered LimitsExceeded and never reaches gcr, so one connection cannot
// take every prompt of the global bound (limits::kPrompts). The count follows what gcr itself holds, from messages no
// caller can forge (counter-review of step 9a, MINOR-A and MINOR-B):
// - a BeginPrompting counts only with the prompter's interface named exactly (GDBus answers any other call itself, so
//   gcr never sees it);
// - a prompt stops counting when gcr ends it: its own outgoing PromptDone (StopPrompting, a closed prompt), an error
//   answering its PromptReady (a caller without the callback object: gcr drops the prompt silently), the caller leaving
//   the bus (NameOwnerChanged from the bus daemon; the bridge listens to all of them), or the bridge letting the
//   prompter's name go (gcr's clients then forget their prompts without stopping them: every count is cleared, and the
//   bridge closes gcr's prompts, Bridge.h). A StopPrompting itself is never counted: gcr answers it with PromptDone.
//
// The filter runs in GDBus's worker thread: it touches only the message and its own state, and an error reply is sent
// from the main loop.

#include "Protocol.h"

#include <gio/gio.h>

#include <QHash>
#include <QPair>
#include <QSet>
#include <QString>

namespace gf::prompter {

    inline constexpr char kCallerProperty[] = "grassfield-caller";
    inline constexpr char kPrompterPath[]   = "/org/gnome/keyring/Prompter";
    inline constexpr char kPrompterIface[]  = "org.gnome.keyring.internal.Prompter";
    inline constexpr char kPrompterName[]   = "org.gnome.keyring.SystemPrompter";
    inline constexpr gsize kMaxPropertyBytes = 16384; // a longer caller string is dropped (a sheet shows far less)

    // The PerformPrompt body (o callback, s type, a{sv} properties, s exchange) with sanitized properties and
    // "grassfield-caller" = `sender` ("" when null). nullptr when `body` is not of that type. Floating reference.
    GVariant* sanitizePerformPrompt(GVariant* body, const char* sender);

    // The (sender, callback path) pairs gcr holds open, as the filter sees them pass.
    class CallerBook {
      public:
        explicit CallerBook(int perCaller) : m_perCaller(perCaller) {}
        // False: `sender` already holds `perCaller` prompts and this one is refused. A pair already open passes (gcr
        // refuses a second BeginPrompting for it itself) and is not counted twice.
        bool begin(const QString& sender, const QString& path);
        void stop(const QString& sender, const QString& path);
        // `name` left the bus.
        void gone(const QString& name);
        void clear() {
            m_open.clear();
        }
        int  open(const QString& sender) const {
            return static_cast<int>(m_open.value(sender).size());
        }
        int callers() const {
            return static_cast<int>(m_open.size());
        }

      private:
        int                            m_perCaller;
        QHash<QString, QSet<QString>> m_open;
    };

    struct FilterState {
        CallerBook book{limits::kPromptsPerCaller};
        // The PromptReady calls gcr sent and that are not answered yet: serial -> (destination, callback path); bounded.
        QHash<quint32, QPair<QString, QString>> readyCalls;
    };

    // What the filter decides for one incoming message. It takes `message` and returns what GDBus dispatches: the same
    // message, a sanitized copy, or nullptr when it is refused, in which case *reply is the error reply for its sender
    // (a new reference). `self` is the bridge's unique name. Signals and calls for anything else pass untouched.
    GDBusMessage* filterIncoming(FilterState& state, const char* self, GDBusMessage* message, GDBusMessage** reply);

    // What the filter notes of one outgoing message (gcr's PromptReady and PromptDone); the message passes unchanged.
    void filterOutgoing(FilterState& state, GDBusMessage* message);

    // The GDBusMessageFilterFunction; `userData` is the FilterState (used by the worker thread only).
    GDBusMessage* promptFilter(GDBusConnection* connection, GDBusMessage* message, gboolean incoming, gpointer userData);

} // namespace gf::prompter
