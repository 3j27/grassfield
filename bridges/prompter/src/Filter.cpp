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

    bool CallerBook::begin(const QString& sender, const QString& path) {
        auto it = m_open.find(sender);
        if (it != m_open.end() && it->contains(path))
            return true;
        if (it != m_open.end() && it->size() >= m_perCaller)
            return false;
        m_open[sender].insert(path);
        return true;
    }

    void CallerBook::stop(const QString& sender, const QString& path) {
        auto it = m_open.find(sender);
        if (it == m_open.end())
            return;
        it->remove(path);
        if (it->isEmpty())
            m_open.erase(it);
    }

    void CallerBook::gone(const QString& name) {
        m_open.remove(name);
    }

    namespace {
        // The object path of a (o) body, empty when the body is of another type.
        QString pathArgument(GDBusMessage* message) {
            GVariant* body = g_dbus_message_get_body(message);
            if (!body || !g_variant_is_of_type(body, G_VARIANT_TYPE("(o)")))
                return {};
            const gchar* path = nullptr;
            g_variant_get(body, "(&o)", &path);
            return QString::fromUtf8(path);
        }

        GDBusMessage* refuse(GDBusMessage* message, GDBusMessage** reply, const char* error, const char* text) {
            *reply = g_dbus_message_new_method_error_literal(message, error, text);
            g_object_unref(message);
            return nullptr;
        }

        struct PendingReply {
            GDBusConnection* connection;
            GDBusMessage*    reply;
        };

        gboolean sendReply(gpointer data) {
            auto* pending = static_cast<PendingReply*>(data);
            g_dbus_connection_send_message(pending->connection, pending->reply, G_DBUS_SEND_MESSAGE_FLAGS_NONE, nullptr, nullptr);
            g_object_unref(pending->reply);
            g_object_unref(pending->connection);
            delete pending;
            return G_SOURCE_REMOVE;
        }
    } // namespace

    namespace {
        constexpr char kCallbackIface[] = "org.gnome.keyring.internal.Prompter.Callback";
        constexpr int  kReadyCalls      = 4096; // more unanswered PromptReady calls than that: the oldest are forgotten
    } // namespace

    GDBusMessage* filterIncoming(FilterState& state, const char* self, GDBusMessage* message, GDBusMessage** reply) {
        *reply                      = nullptr;
        CallerBook&            book = state.book;
        const GDBusMessageType type = g_dbus_message_get_message_type(message);
        const char*            from = g_dbus_message_get_sender(message);
        const QString          sender = QString::fromUtf8(from ? from : "");

        // Only the bus daemon sends NameOwnerChanged. A connection that left forgets what it held; the prompter's name
        // leaving the bridge makes gcr's clients forget their prompts without stopping them: every count goes.
        if (type == G_DBUS_MESSAGE_TYPE_SIGNAL) {
            GVariant* body = g_dbus_message_get_body(message);
            if (sender == QLatin1String("org.freedesktop.DBus") && g_strcmp0(g_dbus_message_get_member(message), "NameOwnerChanged") == 0
                && g_strcmp0(g_dbus_message_get_interface(message), "org.freedesktop.DBus") == 0 && body
                && g_variant_is_of_type(body, G_VARIANT_TYPE("(sss)"))) {
                const gchar* name     = nullptr;
                const gchar* oldOwner = nullptr;
                const gchar* newOwner = nullptr;
                g_variant_get(body, "(&s&s&s)", &name, &oldOwner, &newOwner);
                if (name[0] == ':' && newOwner[0] == '\0') {
                    book.gone(QString::fromUtf8(name));
                    state.forgetReadyOf(QString::fromUtf8(name));
                }
                if (self && *self && std::strcmp(name, kPrompterName) == 0 && std::strcmp(oldOwner, self) == 0 && std::strcmp(newOwner, self) != 0) {
                    book.clear();
                    state.clearReady();
                }
            }
            return message;
        }
        // The answer to one of gcr's PromptReady calls: an error means gcr drops that prompt without a PromptDone.
        if (type == G_DBUS_MESSAGE_TYPE_METHOD_RETURN || type == G_DBUS_MESSAGE_TYPE_ERROR) {
            const auto it = state.readyCalls.find(g_dbus_message_get_reply_serial(message));
            if (it != state.readyCalls.end()) {
                const QPair<QString, QString> slot = it.value();
                if (type == G_DBUS_MESSAGE_TYPE_ERROR && slot.first == sender)
                    book.stop(slot.first, slot.second);
                state.forgetReady(slot);
            }
            return message;
        }
        if (type != G_DBUS_MESSAGE_TYPE_METHOD_CALL || g_strcmp0(g_dbus_message_get_path(message), kPrompterPath) != 0)
            return message;
        const char* iface  = g_dbus_message_get_interface(message);
        const char* member = g_dbus_message_get_member(message);
        if (iface && std::strcmp(iface, kPrompterIface) != 0)
            return message; // another interface at that path: GDBus answers it as unknown, gcr never sees it

        // Counted only with the interface named: GDBus answers an interface-less BeginPrompting itself (counter-review
        // MINOR-B). StopPrompting is never counted here: gcr answers it with a PromptDone, which filterOutgoing counts.
        if (g_strcmp0(member, "BeginPrompting") == 0) {
            const QString path = pathArgument(message);
            if (iface && !path.isEmpty() && !book.begin(sender, path))
                return refuse(message, reply, "org.freedesktop.DBus.Error.LimitsExceeded", "Too many prompts open for this caller");
            return message;
        }
        if (g_strcmp0(member, "PerformPrompt") != 0)
            return message;

        GVariant* body = sanitizePerformPrompt(g_dbus_message_get_body(message), from);
        if (!body)
            return refuse(message, reply, "org.freedesktop.DBus.Error.InvalidArgs", "PerformPrompt takes (o callback, s type, a{sv} properties, s exchange)");
        g_variant_ref_sink(body);
        GError*       error = nullptr;
        GDBusMessage* copy  = g_dbus_message_copy(message, &error);
        if (!copy) {
            g_clear_error(&error);
            g_variant_unref(body);
            return refuse(message, reply, "org.freedesktop.DBus.Error.Failed", "The prompt could not be handled");
        }
        g_object_unref(message);
        g_dbus_message_set_body(copy, body);
        g_variant_unref(body);
        return copy;
    }

    void filterOutgoing(FilterState& state, GDBusMessage* message) {
        if (g_dbus_message_get_message_type(message) != G_DBUS_MESSAGE_TYPE_METHOD_CALL
            || g_strcmp0(g_dbus_message_get_interface(message), kCallbackIface) != 0)
            return;
        const char* destination = g_dbus_message_get_destination(message);
        const char* path        = g_dbus_message_get_path(message);
        const char* member      = g_dbus_message_get_member(message);
        if (!destination || !path)
            return;
        const QPair<QString, QString> slot{QString::fromUtf8(destination), QString::fromUtf8(path)};
        if (g_strcmp0(member, "PromptDone") == 0) {
            state.book.stop(slot.first, slot.second);
            state.forgetReady(slot); // gcr cancels its own PromptReady when it ends the prompt: no answer may ever come
        } else if (g_strcmp0(member, "PromptReady") == 0) {
            state.forgetReady(slot);
            if (state.readyCalls.size() >= kReadyCalls)
                state.clearReady(); // counts may then stay until their caller leaves: they only hold that caller back
            const quint32 serial = g_dbus_message_get_serial(message);
            state.readyCalls.insert(serial, slot);
            state.readyBySlot.insert(slot, serial);
        }
    }

    void FilterState::forgetReady(const QPair<QString, QString>& slot) {
        const auto it = readyBySlot.find(slot);
        if (it == readyBySlot.end())
            return;
        readyCalls.remove(it.value());
        readyBySlot.erase(it);
    }

    void FilterState::forgetReadyOf(const QString& destination) {
        for (auto it = readyBySlot.begin(); it != readyBySlot.end();) {
            if (it.key().first == destination) {
                readyCalls.remove(it.value());
                it = readyBySlot.erase(it);
            } else {
                ++it;
            }
        }
    }

    GDBusMessage* promptFilter(GDBusConnection* connection, GDBusMessage* message, gboolean incoming, gpointer userData) {
        if (!userData)
            return message;
        auto* state = static_cast<FilterState*>(userData);
        if (!incoming) {
            filterOutgoing(*state, message);
            return message;
        }
        GDBusMessage* reply = nullptr;
        GDBusMessage* out   = filterIncoming(*state, connection ? g_dbus_connection_get_unique_name(connection) : nullptr, message, &reply);
        if (reply) {
            // Sent from the main loop: the filter runs in GDBus's worker thread and must not block it.
            if (connection)
                g_main_context_invoke(nullptr, sendReply, new PendingReply{G_DBUS_CONNECTION(g_object_ref(connection)), reply});
            else
                g_object_unref(reply);
        }
        return out;
    }

} // namespace gf::prompter
