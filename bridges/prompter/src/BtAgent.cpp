#include "BtAgent.h"

#include "Log.h"
#include "Text.h"

#include <gcr/gcr.h>

#include <algorithm>
#include <cstring>
#include <string.h>
#include <time.h>

namespace gf::prompter {

    namespace {
        constexpr int kBusTimeoutMs = 5000;
        // Reading the device's name must not hold the sheet: after this long it is named by its address.
        constexpr int kPropertiesTimeoutMs = 2000;

        // BlueZ 5.87's org.bluez.Agent1 (doc/org.bluez.Agent.rst; the in-arguments GDBus checks every call against).
        constexpr char kIntrospection[] = R"(<node>
  <interface name="org.bluez.Agent1">
    <method name="Release"/>
    <method name="RequestPinCode">
      <arg name="device" type="o" direction="in"/>
      <arg name="pincode" type="s" direction="out"/>
    </method>
    <method name="DisplayPinCode">
      <arg name="device" type="o" direction="in"/>
      <arg name="pincode" type="s" direction="in"/>
    </method>
    <method name="RequestPasskey">
      <arg name="device" type="o" direction="in"/>
      <arg name="passkey" type="u" direction="out"/>
    </method>
    <method name="DisplayPasskey">
      <arg name="device" type="o" direction="in"/>
      <arg name="passkey" type="u" direction="in"/>
      <arg name="entered" type="q" direction="in"/>
    </method>
    <method name="RequestConfirmation">
      <arg name="device" type="o" direction="in"/>
      <arg name="passkey" type="u" direction="in"/>
    </method>
    <method name="RequestAuthorization">
      <arg name="device" type="o" direction="in"/>
    </method>
    <method name="AuthorizeService">
      <arg name="device" type="o" direction="in"/>
      <arg name="uuid" type="s" direction="in"/>
    </method>
    <method name="Cancel"/>
  </interface>
</node>)";

        qint64 monotonicMs() {
            timespec ts{};
            ::clock_gettime(CLOCK_MONOTONIC, &ts);
            return static_cast<qint64>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }

        struct SecureText {
            char*       data;
            std::size_t length;
        };

        void wipeSecureText(gpointer data) {
            auto* text = static_cast<SecureText*>(data);
            explicit_bzero(text->data, text->length);
            gcr_secure_memory_free(text->data);
            delete text;
        }

        QString errorShort(const char* errorName) {
            const char* dot = errorName ? std::strrchr(errorName, '.') : nullptr;
            return dot ? QString::fromLatin1(dot + 1) : QStringLiteral("nothing");
        }

        struct OwnerCheck {
            BtAgent*               agent;
            GDBusMethodInvocation* invocation;
            QString                method;
        };

        struct Generation {
            BtAgent* agent;
            quint64  generation;
        };
    } // namespace

    // A device's properties being read for a request (holds the request: it may end meanwhile).
    struct BtPropertiesCall {
        BtAgent*                   agent;
        std::shared_ptr<BtRequest> request;
    };

    BtAgent::BtAgent(GDBusConnection* systemBus, Sink* sink, int answerTimeoutMs)
        : m_bus(G_DBUS_CONNECTION(g_object_ref(systemBus))), m_sink(sink), m_timeoutMs(answerTimeoutMs), m_cancel(g_cancellable_new()) {}

    BtAgent::~BtAgent() {
        // Every pending call is answered before the agent goes (Rejected: nothing more can be asked).
        endAll(bt::kErrorRejected, QStringLiteral("the bridge stops"), false);
        g_cancellable_cancel(m_cancel);
        if (m_ownerSub)
            g_dbus_connection_signal_unsubscribe(m_bus, m_ownerSub);
        if (m_objectId)
            g_dbus_connection_unregister_object(m_bus, m_objectId);
        // bluetoothd drops an agent whose connection closes (agent.c agent_disconnect); the bridge's goes when the process ends.
        g_dbus_connection_flush_sync(m_bus, nullptr, nullptr);
        g_object_unref(m_cancel);
        g_object_unref(m_bus);
    }

    bool BtAgent::start(QString* error) {
        GError*        gerror = nullptr;
        GDBusNodeInfo* node   = g_dbus_node_info_new_for_xml(kIntrospection, &gerror);
        if (!node) {
            *error = QStringLiteral("the Agent1 introspection: %1").arg(QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        static const GDBusInterfaceVTable vtable = {onMethodCall, nullptr, nullptr, {nullptr}};
        m_objectId = g_dbus_connection_register_object(m_bus, bt::kAgentPath, node->interfaces[0], &vtable, this, nullptr, &gerror);
        g_dbus_node_info_unref(node);
        if (!m_objectId) {
            *error = QStringLiteral("cannot export %1: %2").arg(QLatin1String(bt::kAgentPath), QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        m_ownerSub = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                                                        bt::kBusName, G_DBUS_SIGNAL_FLAGS_NONE, onBluezOwnerChanged, this, nullptr);
        auto* call = new Generation{this, m_generation};
        g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", bt::kBusName), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, m_cancel, onBluezOwner, call);
        log(QStringLiteral("Bluetooth pairing agent ready on %1 (registered while a shell that draws it is connected)")
                .arg(QString::fromUtf8(g_dbus_connection_get_unique_name(m_bus))));
        return true;
    }

    // --- registration -------------------------------------------------------------------------------------------------

    void BtAgent::setWanted(bool wanted) {
        if (wanted == m_wanted)
            return;
        m_wanted = wanted;
        ++m_generation;
        if (wanted) {
            if (!m_bluezOwner.isEmpty())
                sendRegister();
            else
                log(QStringLiteral("bluetoothd is not on the system bus: the pairing agent registers when it comes"));
            return;
        }
        // The shell went: nothing may wait for it.
        endAll(bt::kErrorRejected, QStringLiteral("no shell to ask"), false);
        sendUnregister();
    }

    void BtAgent::sendRegister() {
        m_registerSent = true;
        auto* call     = new Generation{this, m_generation};
        g_dbus_connection_call(m_bus, bt::kBusName, bt::kAgentManagerPath, bt::kAgentManagerIface, "RegisterAgent",
                               g_variant_new("(os)", bt::kAgentPath, bt::kCapability), nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs,
                               m_cancel, onRegisterReply, call);
    }

    void BtAgent::sendUnregister() {
        if (!m_registerSent)
            return;
        m_registerSent = false;
        // Sent after any RegisterAgent on the same connection: bluetoothd handles them in that order.
        g_dbus_connection_call(m_bus, bt::kBusName, bt::kAgentManagerPath, bt::kAgentManagerIface, "UnregisterAgent",
                               g_variant_new("(o)", bt::kAgentPath), nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, nullptr, nullptr,
                               nullptr);
        log(QStringLiteral("Bluetooth pairing agent unregistered (no shell)"));
    }

    void BtAgent::onRegisterReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<Generation*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (reply)
            g_variant_unref(reply);
        const bool cancelled = error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        if (!cancelled && call->generation == call->agent->m_generation) {
            BtAgent* agent = call->agent;
            // AlreadyExists: this connection's agent is still registered (agent.c register_agent): it is ours.
            gchar*     remote  = error ? g_dbus_error_get_remote_error(error) : nullptr;
            const bool already = g_strcmp0(remote, "org.bluez.Error.AlreadyExists") == 0;
            g_free(remote);
            if (reply || already) {
                log(QStringLiteral("registered with bluetoothd as a %1 agent%2").arg(QLatin1String(bt::kCapability), already ? QStringLiteral(" (already)") : QString()));
                // The default agent is the one bluetoothd asks for pairings no application started with its own agent (and
                // for Settings' Pair, which registers none): the last agent to ask is the default (agent.c add_default_agent).
                auto* next = new Generation{agent, agent->m_generation};
                g_dbus_connection_call(agent->m_bus, bt::kBusName, bt::kAgentManagerPath, bt::kAgentManagerIface, "RequestDefaultAgent",
                                       g_variant_new("(o)", bt::kAgentPath), nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, agent->m_cancel,
                                       onDefaultReply, next);
            } else {
                log(QStringLiteral("bluetoothd refused the pairing agent: %1").arg(flatten(QString::fromUtf8(error ? error->message : ""), 256)));
            }
        }
        g_clear_error(&error);
        delete call;
    }

    void BtAgent::onDefaultReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<Generation*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (reply)
            g_variant_unref(reply);
        const bool cancelled = error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        if (!cancelled && call->generation == call->agent->m_generation) {
            if (reply)
                log(QStringLiteral("the default pairing agent of bluetoothd"));
            else
                log(QStringLiteral("bluetoothd did not make the agent its default: %1").arg(flatten(QString::fromUtf8(error ? error->message : ""), 256)));
        }
        g_clear_error(&error);
        delete call;
    }

    void BtAgent::onBluezOwner(GObject* source, GAsyncResult* result, gpointer data) {
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
            call->agent->bluezOwnerIs(owner);
        delete call;
    }

    void BtAgent::onBluezOwnerChanged(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/,
                                      const gchar* /*signal*/, GVariant* parameters, gpointer self) {
        // Only the bus daemon's NameOwnerChanged counts (GDBus matches the sender too; checked again).
        if (g_strcmp0(sender, "org.freedesktop.DBus") != 0 || !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sss)")))
            return;
        const gchar* name     = nullptr;
        const gchar* oldOwner = nullptr;
        const gchar* newOwner = nullptr;
        g_variant_get(parameters, "(&s&s&s)", &name, &oldOwner, &newOwner);
        if (g_strcmp0(name, bt::kBusName) == 0)
            static_cast<BtAgent*>(self)->bluezOwnerIs(QString::fromUtf8(newOwner));
    }

    void BtAgent::bluezOwnerIs(const QString& owner) {
        if (owner == m_bluezOwner)
            return;
        const bool hadOwner = !m_bluezOwner.isEmpty();
        m_bluezOwner        = owner;
        // Every request came from the owner that left: none of them can be answered any more.
        if (hadOwner)
            endAll(bt::kErrorRejected, QStringLiteral("bluetoothd left the bus"), true);
        // A bluetoothd that (re)appears knows no agent: register again while the shell is there.
        m_registerSent = false;
        if (!owner.isEmpty() && m_wanted)
            sendRegister();
    }

    // --- calls from the bus ---------------------------------------------------------------------------------------------

    void BtAgent::onMethodCall(GDBusConnection* bus, const gchar* /*sender*/, const gchar* /*path*/, const gchar* /*iface*/, const gchar* method,
                               GVariant* /*parameters*/, GDBusMethodInvocation* invocation, gpointer self) {
        auto* agent = static_cast<BtAgent*>(self);
        // Who owns org.bluez now, asked when the call arrives (a name can change hands at any time): the call is handled
        // only when its sender is that owner. The parameters stay with the invocation meanwhile.
        auto* check = new OwnerCheck{agent, invocation, QString::fromUtf8(method)};
        g_dbus_connection_call(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", bt::kBusName), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, agent->m_cancel,
                               onOwnerChecked, check);
    }

    void BtAgent::onOwnerChecked(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     check = static_cast<OwnerCheck*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            // The agent is gone (never touched here): nothing more is asked.
            g_dbus_method_invocation_return_dbus_error(check->invocation, bt::kErrorRejected, "The agent stopped");
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
        BtAgent*      agent  = check->agent;
        const QString sender = QString::fromUtf8(g_dbus_method_invocation_get_sender(check->invocation));
        if (owner.isEmpty() || sender != owner) {
            qint64 suppressed = 0;
            if (agent->m_refusals.allow(monotonicMs(), &suppressed))
                log(QStringLiteral("refused %1 from %2: not the owner of %3%4")
                        .arg(flatten(check->method, 32), flatten(sender, 64), QLatin1String(bt::kBusName),
                             suppressed ? QStringLiteral(" (and %1 refused call(s) not logged)").arg(suppressed) : QString()));
            g_dbus_method_invocation_return_dbus_error(check->invocation, bt::kErrorRejected, "Only bluetoothd may call this agent");
        } else {
            agent->dispatch(check->method, g_dbus_method_invocation_get_parameters(check->invocation), check->invocation);
        }
        delete check;
    }

    void BtAgent::dispatch(const QString& method, GVariant* parameters, GDBusMethodInvocation* invocation) {
        if (method == QLatin1String("Release")) {
            // bluetoothd releases its agents only as it stops (btd_agent_cleanup -> agent_destroy -> agent_release, agent.c
            // :1054-1061, :930-945), a pending request cancelled first (agent_release -> agent_cancel, :75-92); never after an
            // UnregisterAgent or a closed connection, whose agent_disconnect clears the watch agent_destroy releases on
            // (:174-188). Nothing else to do: a stopping bluetoothd leaves the bus, which ends every request, and the agent
            // registers again with the next bluetoothd. A Release from anyone else never gets here (the sender check).
            g_dbus_method_invocation_return_value(invocation, nullptr);
            log(QStringLiteral("Release from bluetoothd"));
            return;
        }
        if (method == QLatin1String("Cancel")) {
            // "The agent request failed before a reply was returned" (org.bluez.Agent.rst): bluetoothd sends it only for its
            // one request still waiting for a reply (agent_cancel needs agent->request->call, agent.c:307-321; one request
            // per agent, :407-428, :551-552), so it ends only the calls not answered yet. A code shown has had its reply
            // (or wants none) and belongs to a pairing of its own: it ends on its own signs (ADR-0035 decision 10-16; opus
            // review of step 10, MINOR: a Cancel for one device's confirmation withdrew another device's code).
            g_dbus_method_invocation_return_value(invocation, nullptr);
            endPending(bt::kErrorCanceled, QStringLiteral("bluetoothd cancelled it"));
            return;
        }
        // Copies: a call answered at once (DisplayPinCode, DisplayPasskey) frees its parameters with it.
        const gchar* pathArg = nullptr;
        g_variant_get_child(parameters, 0, "&o", &pathArg);
        const QByteArray devicePath(pathArg);
        const QByteArray owner(g_dbus_method_invocation_get_sender(invocation));
        const char*      path = devicePath.constData();
        QString          address;
        if (!bt::validDevicePath(path, &address)) {
            log(QStringLiteral("%1 refused: not a device of bluetoothd").arg(flatten(method, 32)));
            g_dbus_method_invocation_return_dbus_error(invocation, bt::kErrorRejected, "Not a Bluetooth device");
            return;
        }
        if (!m_wanted) {
            // A call that reaches the agent while no shell draws the sheet (it is unregistered, or about to be).
            log(QStringLiteral("%1 for %2 answered Rejected: no shell to ask").arg(flatten(method, 32), address));
            g_dbus_method_invocation_return_dbus_error(invocation, bt::kErrorRejected, "No one to ask");
            return;
        }
        if (method == QLatin1String("RequestPinCode")) {
            begin(bt::Mode::Pin, devicePath, owner, address, invocation, QString(), 0);
        } else if (method == QLatin1String("RequestPasskey")) {
            begin(bt::Mode::Passkey, devicePath, owner, address, invocation, QString(), 0);
        } else if (method == QLatin1String("RequestConfirmation")) {
            guint32 passkey = 0;
            g_variant_get_child(parameters, 1, "u", &passkey);
            const QString code = bt::formatPasskey(passkey);
            if (code.isEmpty()) {
                log(QStringLiteral("RequestConfirmation for %1 refused: a passkey over 999999").arg(address));
                g_dbus_method_invocation_return_dbus_error(invocation, bt::kErrorRejected, "Invalid passkey");
                return;
            }
            begin(bt::Mode::Confirm, devicePath, owner, address, invocation, code, 0);
        } else if (method == QLatin1String("RequestAuthorization")) {
            begin(bt::Mode::Authorize, devicePath, owner, address, invocation, QString(), 0);
        } else if (method == QLatin1String("AuthorizeService")) {
            const gchar* uuid = nullptr;
            g_variant_get_child(parameters, 1, "&s", &uuid);
            QString       canonical;
            const QString service = bt::serviceKey(uuid, &canonical);
            if (service.isEmpty()) {
                log(QStringLiteral("AuthorizeService for %1 refused: not a UUID").arg(address));
                g_dbus_method_invocation_return_dbus_error(invocation, bt::kErrorRejected, "Invalid UUID");
                return;
            }
            begin(bt::Mode::AuthorizeService, devicePath, owner, address, invocation, QString(), 0, service, canonical);
        } else if (method == QLatin1String("DisplayPinCode")) {
            const gchar* pin = nullptr;
            g_variant_get_child(parameters, 1, "&s", &pin);
            if (!bt::validPin(pin, pin ? std::strlen(pin) : 0)) {
                log(QStringLiteral("DisplayPinCode for %1 refused: not 1 to 16 letters or digits").arg(address));
                g_dbus_method_invocation_return_dbus_error(invocation, bt::kErrorRejected, "Invalid PIN");
                return;
            }
            const QString code = QString::fromLatin1(pin);
            // Answered at once: bluetoothd hands the PIN to the controller when this call returns (device.c:7609-7618);
            // the sheet shows it until the pairing ends.
            g_dbus_method_invocation_return_value(invocation, nullptr);
            endCodesShown(QStringLiteral("another code shown"));
            begin(bt::Mode::DisplayPin, devicePath, owner, address, nullptr, code, 0);
        } else if (method == QLatin1String("DisplayPasskey")) {
            guint32 passkey = 0;
            guint16 entered = 0;
            g_variant_get_child(parameters, 1, "u", &passkey);
            g_variant_get_child(parameters, 2, "q", &entered);
            // bluetoothd expects no reply (gdbus/object.c g_dbus_send_message sets NO_REPLY_EXPECTED): GDBus sends none.
            g_dbus_method_invocation_return_value(invocation, nullptr);
            displayPasskey(devicePath, owner, address, passkey, entered);
        } else {
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
        }
    }

    void BtAgent::displayPasskey(const QByteArray& path, const QByteArray& owner, const QString& address, guint32 passkey, guint16 entered) {
        const QString code = bt::formatPasskey(passkey);
        if (code.isEmpty()) {
            log(QStringLiteral("DisplayPasskey for %1 ignored: a passkey over 999999").arg(address));
            return;
        }
        const int digits = std::min<int>(entered, bt::kDigits);
        // The same code for the same device: only how many digits were typed changed (BlueZ calls again for each one).
        for (const Request& r : QList<Request>(m_requests)) {
            if (!r->ended && r->mode == bt::Mode::DisplayPasskey && r->path == path && r->code == code) {
                if (digits != r->entered) {
                    r->entered = digits;
                    if (!r->id.isEmpty())
                        m_sink->progressBt(r->id, digits); // may end it (the shell lost while sending)
                }
                return;
            }
        }
        endCodesShown(QStringLiteral("another code shown"));
        begin(bt::Mode::DisplayPasskey, path, owner, address, nullptr, code, digits);
    }

    void BtAgent::begin(bt::Mode mode, const QByteArray& path, const QByteArray& owner, const QString& address, GDBusMethodInvocation* invocation,
                        const QString& code, int entered, const QString& service, const QString& uuid) {
        auto request        = std::make_shared<BtRequest>();
        request->agent      = this;
        request->invocation = invocation;
        request->path       = path;
        request->owner      = owner;
        request->mode       = mode;
        request->code       = code;
        request->entered    = entered;
        request->service    = service;
        request->uuid       = uuid;
        request->device     = bt::deviceView(nullptr, address);
        m_requests.append(request);
        // The device's name, from the same owner whose call this is (BT3): read without waiting long, named by its address
        // otherwise. A Cancel, a Release or the shell's departure can end the request meanwhile.
        auto* call = new BtPropertiesCall{this, request};
        g_dbus_connection_call(m_bus, owner.constData(), path.constData(), "org.freedesktop.DBus.Properties",
                               "GetAll", g_variant_new("(s)", bt::kDeviceIface), G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
                               kPropertiesTimeoutMs, m_cancel, onDeviceProperties, call);
    }

    void BtAgent::onDeviceProperties(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<BtPropertiesCall*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            // The agent is gone (its destructor answered the request already): nothing is touched.
            g_clear_error(&error);
            delete call;
            return;
        }
        g_clear_error(&error);
        const std::shared_ptr<BtRequest> request = call->request;
        BtAgent*                         agent   = call->agent;
        delete call;
        if (reply) {
            GVariant* properties = g_variant_get_child_value(reply, 0);
            request->device      = bt::deviceView(properties, request->device.address);
            g_variant_unref(properties);
            g_variant_unref(reply);
        }
        if (request->ended)
            return; // cancelled, released or the shell went while the name was read
        agent->submit(request);
    }

    void BtAgent::submit(const Request& request) {
        const QString id = m_sink->submitBt(request.get());
        if (request->ended)
            return; // ended while it was sent (the shell went)
        if (id.isEmpty()) {
            endWith(request, bt::kErrorRejected, QStringLiteral("the sheet cannot ask now (no shell, or 8 requests outstanding)"), false);
            return;
        }
        request->id      = id;
        request->timeout = g_timeout_add(static_cast<guint>(m_timeoutMs), onTimeout, request.get());
        if (bt::isDisplay(request->mode)) {
            // A code shown goes once the pairing is over, which bluetoothd never says with a Cancel (BtPairing.h): the device
            // paired, its link down, or the device gone (decision 10-16).
            request->pairedSub  = g_dbus_connection_signal_subscribe(m_bus, request->owner.constData(), "org.freedesktop.DBus.Properties",
                                                                     "PropertiesChanged", request->path.constData(), bt::kDeviceIface,
                                                                     G_DBUS_SIGNAL_FLAGS_NONE, onDeviceChanged, this, nullptr);
            request->removedSub = g_dbus_connection_signal_subscribe(m_bus, request->owner.constData(), "org.freedesktop.DBus.ObjectManager",
                                                                     "InterfacesRemoved", "/", nullptr, G_DBUS_SIGNAL_FLAGS_NONE, onDeviceRemoved,
                                                                     this, nullptr);
        }
        log(QStringLiteral("request %1: bluetooth (%2) for %3").arg(id, bt::modeName(request->mode), request->device.address));
    }

    void BtAgent::onDeviceChanged(GDBusConnection* /*bus*/, const gchar* sender, const gchar* path, const gchar* /*iface*/, const gchar* /*signal*/,
                                  GVariant* parameters, gpointer self) {
        auto* agent = static_cast<BtAgent*>(self);
        if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sa{sv}as)")))
            return;
        const gchar* iface = nullptr;
        g_variant_get_child(parameters, 0, "&s", &iface);
        GVariant*  changed   = g_variant_get_child_value(parameters, 1);
        gboolean   paired    = FALSE;
        gboolean   bonded    = FALSE;
        gboolean   connected = TRUE;
        const bool device    = g_strcmp0(iface, bt::kDeviceIface) == 0;
        const bool done      = device && ((g_variant_lookup(changed, "Paired", "b", &paired) && paired) || (g_variant_lookup(changed, "Bonded", "b", &bonded) && bonded));
        // The pairing's link went down: the device gave up (a failed or abandoned incoming pairing gets no Cancel either).
        const bool gone = device && g_variant_lookup(changed, "Connected", "b", &connected) && !connected;
        g_variant_unref(changed);
        if (!done && !gone)
            return;
        // Only from the owner whose call showed the code (GDBus matched it; checked again).
        for (const Request& r : QList<Request>(agent->m_requests)) {
            if (!r->ended && bt::isDisplay(r->mode) && r->path == path && r->owner == sender)
                agent->endWith(r, nullptr, done ? QStringLiteral("the device is paired") : QStringLiteral("the device disconnected"), true);
        }
    }

    void BtAgent::onDeviceRemoved(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/, const gchar* /*signal*/,
                                  GVariant* parameters, gpointer self) {
        auto* agent = static_cast<BtAgent*>(self);
        if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(oas)")))
            return;
        const gchar*  object     = nullptr;
        const gchar** interfaces = nullptr;
        g_variant_get(parameters, "(&o^a&s)", &object, &interfaces);
        bool device = false;
        for (const gchar** i = interfaces; i && *i; ++i)
            device = device || g_strcmp0(*i, bt::kDeviceIface) == 0;
        g_free(interfaces);
        if (!device)
            return;
        // The device object went (a temporary device bluetoothd forgot): its pairing is over.
        for (const Request& r : QList<Request>(agent->m_requests)) {
            if (!r->ended && bt::isDisplay(r->mode) && r->path == object && r->owner == sender)
                agent->endWith(r, nullptr, QStringLiteral("the device was removed"), true);
        }
    }

    gboolean BtAgent::onTimeout(gpointer data) {
        auto*    raw   = static_cast<BtRequest*>(data);
        BtAgent* agent = raw->agent;
        raw->timeout   = 0;
        if (const Request request = agent->find(raw)) {
            agent->endWith(request, bt::kErrorRejected,
                           QStringLiteral("no answer within %1 s (bluetoothd stops waiting at 60 s)").arg(agent->m_timeoutMs / 1000), true);
        }
        return G_SOURCE_REMOVE;
    }

    // --- ends -------------------------------------------------------------------------------------------------------------

    BtAgent::Request BtAgent::find(BtRequest* request) const {
        for (const Request& r : m_requests) {
            if (r.get() == request)
                return r;
        }
        return nullptr;
    }

    BtAgent::Request BtAgent::take(BtRequest* request) {
        for (qsizetype i = 0; i < m_requests.size(); ++i) {
            if (m_requests.at(i).get() == request) {
                Request r = m_requests.at(i);
                m_requests.removeAt(i);
                return r;
            }
        }
        return nullptr;
    }

    void BtAgent::finish(const Request& request) {
        take(request.get());
        request->ended = true;
        if (request->timeout) {
            g_source_remove(request->timeout);
            request->timeout = 0;
        }
        if (request->pairedSub) {
            g_dbus_connection_signal_unsubscribe(m_bus, request->pairedSub);
            request->pairedSub = 0;
        }
        if (request->removedSub) {
            g_dbus_connection_signal_unsubscribe(m_bus, request->removedSub);
            request->removedSub = 0;
        }
    }

    void BtAgent::endWith(const Request& request, const char* errorName, const QString& why, bool tellShell) {
        if (request->ended)
            return;
        finish(request);
        const QString who = request->id.isEmpty() ? QStringLiteral("a %1 call").arg(bt::modeName(request->mode)) : QStringLiteral("request %1").arg(request->id);
        if (request->invocation) {
            log(QStringLiteral("%1 answered %2: %3").arg(who, errorShort(errorName ? errorName : bt::kErrorRejected), why));
            g_dbus_method_invocation_return_dbus_error(request->invocation, errorName ? errorName : bt::kErrorRejected, why.toUtf8().constData());
            request->invocation = nullptr;
        } else {
            log(QStringLiteral("%1 ended: %2").arg(who, why));
        }
        // Last: the shell's side can call back into the agent (a write error ends the shell, which refuses its requests).
        if (tellShell && !request->id.isEmpty())
            m_sink->withdrawBt(request->id);
    }

    void BtAgent::endPending(const char* errorName, const QString& why) {
        const QList<Request> all = m_requests;
        int                  n   = 0;
        for (const Request& request : all) {
            if (!request->ended && request->invocation) {
                endWith(request, errorName, why, true);
                ++n;
            }
        }
        if (n == 0)
            log(QStringLiteral("Cancel from bluetoothd: no call waiting for its reply"));
    }

    void BtAgent::endCodesShown(const QString& why) {
        // At most one code shown at a time (decision 10-16): the newest is the pairing bluetoothd is doing now, and a device
        // that keeps starting pairings (a new address each time) can hold one place of the shared bound, never more.
        const QList<Request> all = m_requests;
        for (const Request& request : all) {
            if (!request->ended && bt::isDisplay(request->mode))
                endWith(request, nullptr, why, true);
        }
    }

    void BtAgent::endAll(const char* errorName, const QString& why, bool tellShell) {
        const QList<Request> all = m_requests;
        for (const Request& request : all)
            endWith(request, errorName, why, tellShell);
    }

    void BtAgent::answerPin(BtRequest* raw, char* securePin, std::size_t length) {
        const Request request = find(raw);
        if (!request || request->ended || !request->invocation || request->mode != bt::Mode::Pin) {
            explicit_bzero(securePin, length);
            gcr_secure_memory_free(securePin);
            return;
        }
        finish(request);
        // The reply's string is the secure buffer itself; GDBus marshals a copy into the message it writes.
        auto*     text  = new SecureText{securePin, length + 1};
        GVariant* value = g_variant_new_from_data(G_VARIANT_TYPE_STRING, securePin, length + 1, TRUE, wipeSecureText, text);
        g_dbus_method_invocation_return_value(request->invocation, g_variant_new_tuple(&value, 1));
        request->invocation = nullptr;
        log(QStringLiteral("request %1 answered: the PIN went to bluetoothd").arg(request->id));
    }

    void BtAgent::answerPasskey(BtRequest* raw, guint32 passkey) {
        const Request request = find(raw);
        if (!request || request->ended || !request->invocation || request->mode != bt::Mode::Passkey || passkey > 999999)
            return;
        finish(request);
        g_dbus_method_invocation_return_value(request->invocation, g_variant_new("(u)", passkey));
        request->invocation = nullptr;
        log(QStringLiteral("request %1 answered: the passkey went to bluetoothd").arg(request->id));
    }

    void BtAgent::answerYes(BtRequest* raw) {
        const Request request = find(raw);
        if (!request || request->ended || !request->invocation
            || (request->mode != bt::Mode::Confirm && request->mode != bt::Mode::Authorize && request->mode != bt::Mode::AuthorizeService))
            return;
        finish(request);
        g_dbus_method_invocation_return_value(request->invocation, nullptr);
        request->invocation = nullptr;
        log(QStringLiteral("request %1 answered: Connect (%2)").arg(request->id, bt::modeName(request->mode)));
    }

    void BtAgent::refuse(BtRequest* raw, const char* errorName, const QString& why) {
        if (const Request request = find(raw))
            endWith(request, errorName, why, false);
    }

    void BtAgent::cancelDisplay(BtRequest* raw) {
        const Request request = find(raw);
        if (!request || request->ended || !bt::isDisplay(request->mode))
            return;
        endWith(request, nullptr, QStringLiteral("the user cancelled"), false);
        // Stops a pairing that Pair() started (Settings'); bluetoothd answers DoesNotExist for one the device started, which
        // then ends at the device's own time limit (nobody types the code).
        g_dbus_connection_call(m_bus, request->owner.constData(), request->path.constData(), bt::kDeviceIface, "CancelPairing", nullptr, nullptr,
                               G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, m_cancel, onCancelPairingReply, nullptr);
    }

    void BtAgent::onCancelPairingReply(GObject* source, GAsyncResult* result, gpointer /*data*/) {
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (reply) {
            g_variant_unref(reply);
            log(QStringLiteral("bluetoothd stopped the pairing (CancelPairing)"));
        } else if (!(error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))) {
            gchar* remote = error ? g_dbus_error_get_remote_error(error) : nullptr;
            log(QStringLiteral("CancelPairing: %1").arg(flatten(QString::fromUtf8(remote ? remote : (error ? error->message : "")), 128)));
            g_free(remote);
        }
        g_clear_error(&error);
    }

} // namespace gf::prompter
