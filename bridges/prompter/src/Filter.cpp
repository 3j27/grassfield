#include "Filter.h"

#include <cstring>

namespace gf::prompter {

    namespace {
        struct Allowed {
            const char* name;
            const char* type;
        };
        // GcrPrompt's properties a caller sets (gcr/gcr-prompt.c); "password-strength" is the prompter's answer, never the
        // caller's.
        constexpr Allowed kAllowed[] = {
            {"title", "s"},          {"message", "s"},        {"description", "s"},    {"warning", "s"},
            {"choice-label", "s"},   {"choice-chosen", "b"},  {"password-new", "b"},   {"caller-window", "s"},
            {"continue-label", "s"}, {"cancel-label", "s"},
        };

        const Allowed* allowed(const char* name) {
            for (const Allowed& a : kAllowed) {
                if (std::strcmp(a.name, name) == 0)
                    return &a;
            }
            return nullptr;
        }
    } // namespace

    GVariant* sanitizePerformPrompt(GVariant* body, const char* sender) {
        if (!body || !g_variant_is_of_type(body, G_VARIANT_TYPE("(osa{sv}s)")))
            return nullptr;
        const gchar* callback = nullptr;
        const gchar* type     = nullptr;
        const gchar* exchange = nullptr;
        GVariantIter* iter    = nullptr;
        g_variant_get(body, "(&o&sa{sv}&s)", &callback, &type, &iter, &exchange);

        GVariantBuilder properties;
        g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
        const gchar* name  = nullptr;
        GVariant*    value = nullptr;
        while (g_variant_iter_loop(iter, "{&sv}", &name, &value)) {
            const Allowed* a = allowed(name);
            if (!a || !g_variant_is_of_type(value, G_VARIANT_TYPE(a->type)))
                continue;
            if (std::strcmp(a->type, "s") == 0) {
                gsize length = 0;
                g_variant_get_string(value, &length);
                if (length > kMaxPropertyBytes)
                    continue;
            }
            g_variant_builder_add(&properties, "{sv}", name, value);
        }
        g_variant_iter_free(iter);
        g_variant_builder_add(&properties, "{sv}", kCallerProperty, g_variant_new_string(sender ? sender : ""));
        return g_variant_new("(osa{sv}s)", callback, type, &properties, exchange);
    }

    GDBusMessage* promptFilter(GDBusConnection* /*connection*/, GDBusMessage* message, gboolean incoming, gpointer /*userData*/) {
        if (!incoming || g_dbus_message_get_message_type(message) != G_DBUS_MESSAGE_TYPE_METHOD_CALL)
            return message;
        if (g_strcmp0(g_dbus_message_get_path(message), kPrompterPath) != 0 || g_strcmp0(g_dbus_message_get_member(message), "PerformPrompt") != 0)
            return message;
        const char* iface = g_dbus_message_get_interface(message);
        if (iface && std::strcmp(iface, kPrompterIface) != 0)
            return message; // another interface at that path: GDBus answers it as unknown, gcr never sees it

        GVariant* body = sanitizePerformPrompt(g_dbus_message_get_body(message), g_dbus_message_get_sender(message));
        if (!body) {
            g_object_unref(message); // not gcr's shape: dropped, never dispatched
            return nullptr;
        }
        g_variant_ref_sink(body);
        GError*       error = nullptr;
        GDBusMessage* copy  = g_dbus_message_copy(message, &error);
        g_object_unref(message);
        if (!copy) {
            g_clear_error(&error);
            g_variant_unref(body);
            return nullptr;
        }
        g_dbus_message_set_body(copy, body);
        g_variant_unref(body);
        return copy;
    }

} // namespace gf::prompter
