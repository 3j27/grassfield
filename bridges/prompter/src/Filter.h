#pragma once

// How the bridge learns who performs a gcr prompt (ADR-0035 decision 9-1). libgcr's GcrSystemPrompter runs the protocol
// and the exchange, and creates the GcrPrompt object without telling it which caller it serves. Before any incoming
// message is dispatched, a filter on the bridge's bus connection rewrites the PerformPrompt calls addressed to the
// prompter object: their properties keep only GcrPrompt's own, with the right types and bounded strings, and the private
// property "grassfield-caller" is set to the message's sender, which the bus daemon writes and no client can choose. gcr
// then sets those properties on the caller's prompt (prompt_update_properties) right before it asks the prompt for a
// password or a confirmation, so the prompt knows its caller from the bus header alone. A PerformPrompt of another shape
// is dropped (gcr would refuse it anyway). The filter runs in GDBus's worker thread and touches nothing but the message.

#include <gio/gio.h>

namespace gf::prompter {

    inline constexpr char kCallerProperty[] = "grassfield-caller";
    inline constexpr char kPrompterPath[]   = "/org/gnome/keyring/Prompter";
    inline constexpr char kPrompterIface[]  = "org.gnome.keyring.internal.Prompter";
    inline constexpr char kPrompterName[]   = "org.gnome.keyring.SystemPrompter";
    inline constexpr gsize kMaxPropertyBytes = 16384; // a longer caller string is dropped (a sheet shows far less)

    // The PerformPrompt body (o callback, s type, a{sv} properties, s exchange) with sanitized properties and
    // "grassfield-caller" = `sender` ("" when null). nullptr when `body` is not of that type. Floating reference.
    GVariant* sanitizePerformPrompt(GVariant* body, const char* sender);

    // The GDBusMessageFilterFunction.
    GDBusMessage* promptFilter(GDBusConnection* connection, GDBusMessage* message, gboolean incoming, gpointer userData);

} // namespace gf::prompter
