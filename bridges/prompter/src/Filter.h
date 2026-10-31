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
// The same filter keeps the count of the prompts each connection holds open in gcr (its BeginPrompting calls not yet
// stopped, NIT-2): beyond limits::kPromptsPerCaller a BeginPrompting is answered LimitsExceeded and never reaches gcr, so
// one connection cannot take every prompt of the global bound (limits::kPrompts). A connection's count goes when it
// stops prompting or leaves the bus (the bridge subscribes to every NameOwnerChanged so that the filter sees them).
//
// The filter runs in GDBus's worker thread: it touches only the message and its own CallerBook, and an error reply is
// sent from the main loop.

#include "Protocol.h"

#include <gio/gio.h>

#include <QHash>
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

    // What the filter decides for one incoming message. It takes `message` and returns what GDBus dispatches: the same
    // message, a sanitized copy, or nullptr when it is refused, in which case *reply is the error reply for its sender
    // (a new reference). Signals and calls for anything else pass untouched.
    GDBusMessage* filterIncoming(CallerBook& book, GDBusMessage* message, GDBusMessage** reply);

    struct FilterState {
        CallerBook book{limits::kPromptsPerCaller};
    };

    // The GDBusMessageFilterFunction; `userData` is the FilterState (used by the worker thread only).
    GDBusMessage* promptFilter(GDBusConnection* connection, GDBusMessage* message, gboolean incoming, gpointer userData);

} // namespace gf::prompter
