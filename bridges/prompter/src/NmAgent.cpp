#include "NmAgent.h"

#include "Log.h"
#include "Text.h"

#include <gcr/gcr.h>

#include <cstring>
#include <string.h>
#include <time.h>

namespace gf::prompter {

    namespace {
        constexpr int kBusTimeoutMs = 5000;

        // NetworkManager 1.58's org.freedesktop.NetworkManager.SecretAgent (the in-arguments GDBus checks every call against).
        constexpr char kIntrospection[] = R"(<node>
  <interface name="org.freedesktop.NetworkManager.SecretAgent">
    <method name="GetSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
      <arg name="setting_name" type="s" direction="in"/>
      <arg name="hints" type="as" direction="in"/>
      <arg name="flags" type="u" direction="in"/>
      <arg name="secrets" type="a{sa{sv}}" direction="out"/>
    </method>
    <method name="CancelGetSecrets">
      <arg name="connection_path" type="o" direction="in"/>
      <arg name="setting_name" type="s" direction="in"/>
    </method>
    <method name="SaveSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
    </method>
    <method name="DeleteSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
    </method>
  </interface>
</node>)";

        qint64 monotonicMs() {
            timespec ts{};
            ::clock_gettime(CLOCK_MONOTONIC, &ts);
            return static_cast<qint64>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }

        void wipeAndFree(char* secret, std::size_t length) {
            if (!secret)
                return;
            explicit_bzero(secret, length);
            gcr_secure_memory_free(secret);
        }

        struct OwnerCheck {
            NmAgent*               agent;
            GDBusMethodInvocation* invocation;
            QString                method;
        };

        struct Generation {
            NmAgent* agent;
            quint64  generation;
        };
    } // namespace

    NmAgent::NmAgent(GDBusConnection* systemBus, Sink* sink, int answerTimeoutMs)
        : m_bus(G_DBUS_CONNECTION(g_object_ref(systemBus))), m_sink(sink), m_timeoutMs(answerTimeoutMs), m_cancel(g_cancellable_new()) {}

    NmAgent::~NmAgent() {
        // Every pending call is answered before the agent goes (NoSecrets: nothing more can be asked).
        endAll(nm::kErrorNoSecrets, QStringLiteral("the bridge stops"), false);
        g_cancellable_cancel(m_cancel);
        if (m_ownerSub)
            g_dbus_connection_signal_unsubscribe(m_bus, m_ownerSub);
        if (m_objectId)
            g_dbus_connection_unregister_object(m_bus, m_objectId);
        // NetworkManager drops an agent whose connection closes; the bridge's goes when the process ends.
        g_dbus_connection_flush_sync(m_bus, nullptr, nullptr);
        g_object_unref(m_cancel);
        g_object_unref(m_bus);
    }

    bool NmAgent::start(QString* error) {
        GError*        gerror = nullptr;
        GDBusNodeInfo* node   = g_dbus_node_info_new_for_xml(kIntrospection, &gerror);
        if (!node) {
            *error = QStringLiteral("the SecretAgent introspection: %1").arg(QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        static const GDBusInterfaceVTable vtable = {onMethodCall, nullptr, nullptr, {nullptr}};
        m_objectId = g_dbus_connection_register_object(m_bus, nm::kAgentPath, node->interfaces[0], &vtable, this, nullptr, &gerror);
        g_dbus_node_info_unref(node);
        if (!m_objectId) {
            *error = QStringLiteral("cannot export %1: %2").arg(QLatin1String(nm::kAgentPath), QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        m_ownerSub = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                                                        nm::kBusName, G_DBUS_SIGNAL_FLAGS_NONE, onNmOwnerChanged, this, nullptr);
        auto* call = new Generation{this, m_generation};
        g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", nm::kBusName), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, m_cancel, onNmOwner, call);
        log(QStringLiteral("NetworkManager secret agent ready on %1 (registered while a shell that draws it is connected)")
                .arg(QString::fromUtf8(g_dbus_connection_get_unique_name(m_bus))));
        return true;
    }

    // --- registration -------------------------------------------------------------------------------------------------

    void NmAgent::setWanted(bool wanted) {
        if (wanted == m_wanted)
            return;
        m_wanted = wanted;
        ++m_generation;
        if (wanted) {
            if (!m_nmOwner.isEmpty())
                sendRegister();
            else
                log(QStringLiteral("NetworkManager is not on the system bus: the secret agent registers when it comes"));
            return;
        }
        // The shell went: nothing may wait for it.
        endAll(nm::kErrorNoSecrets, QStringLiteral("no shell to ask"), false);
        sendUnregister();
    }

    void NmAgent::sendRegister() {
        m_registerSent = true;
        auto* call     = new Generation{this, m_generation};
        g_dbus_connection_call(m_bus, nm::kBusName, nm::kAgentManagerPath, nm::kAgentManagerIface, "Register", g_variant_new("(s)", nm::kIdentifier),
                               nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, m_cancel, onRegisterReply, call);
    }

    void NmAgent::sendUnregister() {
        if (!m_registerSent)
            return;
        m_registerSent = false;
        // Sent after any Register on the same connection: NetworkManager handles them in that order.
        g_dbus_connection_call(m_bus, nm::kBusName, nm::kAgentManagerPath, nm::kAgentManagerIface, "Unregister", nullptr, nullptr,
                               G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, nullptr, nullptr, nullptr);
        log(QStringLiteral("NetworkManager secret agent unregistered (no shell)"));
    }

    void NmAgent::onRegisterReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<Generation*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (reply)
            g_variant_unref(reply);
        if (!(error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) && call->generation == call->agent->m_generation) {
            if (reply)
                log(QStringLiteral("registered with NetworkManager as %1").arg(QLatin1String(nm::kIdentifier)));
            else
                log(QStringLiteral("NetworkManager refused the secret agent: %1").arg(flatten(QString::fromUtf8(error ? error->message : ""), 256)));
        }
        g_clear_error(&error);
        delete call;
    }

    void NmAgent::onNmOwner(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<Generation*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        QString   owner;
        if (reply) {
            const gchar* name = nullptr;
            g_variant_get(reply, "(&s)", &name);
            owner = QString::fromUtf8(name);
            g_variant_unref(reply);
        }
        const bool cancelled = error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        g_clear_error(&error);
        if (!cancelled)
            call->agent->nmOwnerIs(owner);
        delete call;
    }

    void NmAgent::onNmOwnerChanged(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/, const gchar* /*signal*/,
                                   GVariant* parameters, gpointer self) {
        // Only the bus daemon's NameOwnerChanged counts (GDBus matches the sender too; checked again).
        if (g_strcmp0(sender, "org.freedesktop.DBus") != 0 || !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sss)")))
            return;
        const gchar* name     = nullptr;
        const gchar* oldOwner = nullptr;
        const gchar* newOwner = nullptr;
        g_variant_get(parameters, "(&s&s&s)", &name, &oldOwner, &newOwner);
        if (g_strcmp0(name, nm::kBusName) == 0)
            static_cast<NmAgent*>(self)->nmOwnerIs(QString::fromUtf8(newOwner));
    }

    void NmAgent::nmOwnerIs(const QString& owner) {
        if (owner == m_nmOwner)
            return;
        const bool hadOwner = !m_nmOwner.isEmpty();
        m_nmOwner           = owner;
        // Every request came from the owner that left: none of them can be answered any more.
        if (hadOwner)
            endAll(nm::kErrorNoSecrets, QStringLiteral("NetworkManager left the bus"), true);
        // A NetworkManager that (re)appears knows no agent: register again while the shell is there.
        m_registerSent = false;
        if (!owner.isEmpty() && m_wanted)
            sendRegister();
    }

    // --- calls from the bus ---------------------------------------------------------------------------------------------

    void NmAgent::onMethodCall(GDBusConnection* bus, const gchar* /*sender*/, const gchar* /*path*/, const gchar* /*iface*/, const gchar* method,
                               GVariant* parameters, GDBusMethodInvocation* invocation, gpointer self) {
        auto* agent = static_cast<NmAgent*>(self);
        // Who owns org.freedesktop.NetworkManager now, asked when the call arrives (a name can change hands at any time):
        // the call is handled only when its sender is that owner. The parameters stay with the invocation meanwhile.
        (void)parameters;
        auto* check = new OwnerCheck{agent, invocation, QString::fromUtf8(method)};
        g_dbus_connection_call(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", nm::kBusName), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, agent->m_cancel,
                               onOwnerChecked, check);
    }

    void NmAgent::onOwnerChecked(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     check = static_cast<OwnerCheck*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            // The agent is gone (never touched here): nothing more is asked.
            g_dbus_method_invocation_return_dbus_error(check->invocation, nm::kErrorNoSecrets, "The agent stopped");
            g_clear_error(&error);
            delete check;
            return;
        }
        QString owner;
        if (reply) {
            const gchar* name = nullptr;
            g_variant_get(reply, "(&s)", &name);
            owner = QString::fromUtf8(name);
            g_variant_unref(reply);
        }
        g_clear_error(&error);
        NmAgent*      agent  = check->agent;
        const QString sender = QString::fromUtf8(g_dbus_method_invocation_get_sender(check->invocation));
        if (owner.isEmpty() || sender != owner) {
            qint64 suppressed = 0;
            if (agent->m_refusals.allow(monotonicMs(), &suppressed))
                log(QStringLiteral("refused %1 from %2: not the owner of %3%4")
                        .arg(flatten(check->method, 32), flatten(sender, 64), QLatin1String(nm::kBusName),
                             suppressed ? QStringLiteral(" (and %1 refused call(s) not logged)").arg(suppressed) : QString()));
            g_dbus_method_invocation_return_dbus_error(check->invocation, nm::kErrorPermissionDenied, "Only NetworkManager may call this agent");
        } else {
            agent->dispatch(check->method, g_dbus_method_invocation_get_parameters(check->invocation), check->invocation);
        }
        delete check;
    }

    void NmAgent::dispatch(const QString& method, GVariant* parameters, GDBusMethodInvocation* invocation) {
        if (method == QLatin1String("GetSecrets")) {
            getSecrets(parameters, invocation);
        } else if (method == QLatin1String("CancelGetSecrets")) {
            cancelGetSecrets(parameters, invocation);
        } else if (method == QLatin1String("SaveSecrets")) {
            // NetworkManager asks agents to keep the agent-owned secrets of a connection something else changed. This agent
            // keeps none: it says so, and NetworkManager asks the next agent (a success would make it believe they are saved).
            log(QStringLiteral("SaveSecrets refused: this agent stores no secret"));
            g_dbus_method_invocation_return_dbus_error(invocation, nm::kErrorFailed, "grassfield-prompter stores no secrets");
        } else if (method == QLatin1String("DeleteSecrets")) {
            // Nothing is stored here: nothing to delete.
            g_dbus_method_invocation_return_value(invocation, nullptr);
        } else {
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
        }
    }

    void NmAgent::getSecrets(GVariant* parameters, GDBusMethodInvocation* invocation) {
        GVariant*     connection = nullptr;
        const gchar*  path       = nullptr;
        const gchar*  setting    = nullptr;
        const gchar** hints      = nullptr;
        guint32       flags      = 0;
        g_variant_get(parameters, "(@a{sa{sv}}&o&s^a&su)", &connection, &path, &setting, &hints, &flags);
        const nm::Ask ask = nm::evaluate(connection, setting, hints, flags);
        g_variant_unref(connection);
        g_free(hints);
        const QString settingText = flatten(QString::fromUtf8(setting), 64);
        if (!ask.ask) {
            log(QStringLiteral("GetSecrets for %1 answered NoSecrets: %2").arg(settingText, ask.why));
            g_dbus_method_invocation_return_dbus_error(invocation, nm::kErrorNoSecrets, "No secrets: not asked by this agent");
            return;
        }
        auto request        = std::make_shared<NmRequest>();
        request->agent      = this;
        request->invocation = invocation;
        request->path       = QByteArray(path);
        request->setting    = QByteArray(setting);
        request->ask        = ask;
        m_requests.append(request);
        const QString id = m_sink->submitNm(request.get());
        if (request->ended)
            return; // answered while it was sent (the shell went)
        if (id.isEmpty()) {
            endWith(request, nm::kErrorNoSecrets, QStringLiteral("the sheet cannot ask now (no shell, or 8 requests outstanding)"), false);
            return;
        }
        request->id      = id;
        request->timeout = g_timeout_add(static_cast<guint>(m_timeoutMs), onTimeout, request.get());
        log(QStringLiteral("request %1: nm (%2, %3) for NetworkManager").arg(id, nm::securityName(ask.security), settingText));
    }

    void NmAgent::cancelGetSecrets(GVariant* parameters, GDBusMethodInvocation* invocation) {
        const gchar* path    = nullptr;
        const gchar* setting = nullptr;
        g_variant_get(parameters, "(&o&s)", &path, &setting);
        const QList<Request> all = m_requests;
        int                  n   = 0;
        for (const Request& request : all) {
            if (!request->ended && request->path == path && request->setting == setting) {
                endWith(request, nm::kErrorAgentCanceled, QStringLiteral("NetworkManager cancelled it"), true);
                ++n;
            }
        }
        if (n == 0)
            log(QStringLiteral("CancelGetSecrets for %1: no such request outstanding").arg(flatten(QString::fromUtf8(setting), 64)));
        g_dbus_method_invocation_return_value(invocation, nullptr);
    }

    gboolean NmAgent::onTimeout(gpointer data) {
        auto*    raw   = static_cast<NmRequest*>(data);
        NmAgent* agent = raw->agent;
        raw->timeout   = 0;
        if (const Request request = agent->find(raw)) {
            agent->endWith(request, nm::kErrorNoSecrets,
                           QStringLiteral("no answer within %1 s (NetworkManager stops waiting at 120 s)").arg(agent->m_timeoutMs / 1000), true);
        }
        return G_SOURCE_REMOVE;
    }

    // --- ends -------------------------------------------------------------------------------------------------------------

    NmAgent::Request NmAgent::find(NmRequest* request) const {
        for (const Request& r : m_requests) {
            if (r.get() == request)
                return r;
        }
        return nullptr;
    }

    NmAgent::Request NmAgent::take(NmRequest* request) {
        for (qsizetype i = 0; i < m_requests.size(); ++i) {
            if (m_requests.at(i).get() == request) {
                Request r = m_requests.at(i);
                m_requests.removeAt(i);
                return r;
            }
        }
        return nullptr;
    }

    void NmAgent::endWith(const Request& request, const char* errorName, const QString& why, bool tellShell) {
        if (request->ended)
            return;
        take(request.get());
        request->ended = true;
        if (request->timeout) {
            g_source_remove(request->timeout);
            request->timeout = 0;
        }
        log(QStringLiteral("%1 answered %2: %3")
                .arg(request->id.isEmpty() ? QStringLiteral("a GetSecrets call") : QStringLiteral("request %1").arg(request->id),
                     QString::fromLatin1(std::strrchr(errorName, '.') + 1), why));
        g_dbus_method_invocation_return_dbus_error(request->invocation, errorName, why.toUtf8().constData());
        request->invocation = nullptr;
        // Last: the shell's side can call back into the agent (a write error ends the shell, which refuses its requests).
        if (tellShell && !request->id.isEmpty())
            m_sink->withdrawNm(request->id);
    }

    void NmAgent::endAll(const char* errorName, const QString& why, bool tellShell) {
        const QList<Request> all = m_requests;
        for (const Request& request : all)
            endWith(request, errorName, why, tellShell);
    }

    void NmAgent::answer(NmRequest* raw, char* securePassword, std::size_t length, const QByteArray& identity) {
        const Request request = take(raw);
        if (!request || request->ended) {
            wipeAndFree(securePassword, length);
            return;
        }
        request->ended = true;
        if (request->timeout) {
            g_source_remove(request->timeout);
            request->timeout = 0;
        }
        // The reply's string is the secure buffer itself (NmSecrets.h); GDBus marshals a copy into the message it writes.
        g_dbus_method_invocation_return_value(request->invocation, nm::secretsReply(request->ask, securePassword, length, identity));
        request->invocation = nullptr;
        log(QStringLiteral("request %1 answered: the secret went to NetworkManager").arg(request->id));
    }

    void NmAgent::refuse(NmRequest* raw, const char* errorName, const QString& why) {
        if (const Request request = find(raw))
            endWith(request, errorName, why, false);
    }

} // namespace gf::prompter
