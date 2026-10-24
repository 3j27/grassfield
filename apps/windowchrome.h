// Shared by the three Grassfield apps (R5: one copy). ADR-0015: a window that draws its own chrome (grassfield-ui
// WindowControls / UnifiedToolbar) names its role with an xdg-toplevel tag, and the compositor plugin then keeps its own
// titlebar off that window.
//
// How: a QML Window declares `property string gfChromeRole: "browser"` (or "settings", "viewer", "info"). ChromeTagger, an
// application-wide event filter, sees the window's platform surface being created and, before the toplevel's first commit,
// sends xdg_toplevel_tag_manager_v1.set_toplevel_tag(toplevel, role). Windows without the property (KIO and widget dialogs,
// popups) are never tagged and keep the plugin's titlebar.
//
// Qt has no client for xdg-toplevel-tag-v1 (ADR-0015, Qt side), so this uses one Qt private header (the per-window Wayland
// handle, QtGui/qpa/qplatformwindow_p.h) and the three requests of the protocol written out by hand: no generated code, no
// dependency on xdg-shell. Accepted by the owner (ADR-0015 Q6); the apps are rebuilt with each Qt minor. Anywhere but on
// Wayland, or when the compositor has no tag manager (Hyprland older than 0.45, other compositors), it does nothing.
#pragma once

#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QWindow>
#include <QtGui/qevent.h>
#include <QtGui/qguiapplication_platform.h>
#include <QtGui/qpa/qplatformwindow_p.h>

#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

#include <cstring>

struct xdg_toplevel; // Qt's own proxy type (surfaceRole<xdg_toplevel>() returns it)

namespace grassfield::apps {

namespace detail {

// xdg_toplevel_tag_manager_v1 version 1: destroy(), set_toplevel_tag(object, string), set_toplevel_description(object, string).
// The object argument has no interface here: libwayland only needs the signature to marshal it.
inline const wl_interface *kNoTypes[2] = {nullptr, nullptr};
inline const wl_message kRequests[3] = {
    {"destroy", "", kNoTypes},
    {"set_toplevel_tag", "os", kNoTypes},
    {"set_toplevel_description", "os", kNoTypes},
};
inline const wl_interface kManagerInterface = {"xdg_toplevel_tag_manager_v1", 1, 3, kRequests, 0, nullptr};
constexpr uint32_t kOpSetToplevelTag = 1;

struct Binder {
    uint32_t name = 0;
    uint32_t version = 0;
};

inline void onGlobal(void *data, wl_registry *, uint32_t name, const char *interface, uint32_t version)
{
    if (std::strcmp(interface, kManagerInterface.name) == 0) {
        auto *b = static_cast<Binder *>(data);
        b->name = name;
        b->version = version;
    }
}
inline void onGlobalRemove(void *, wl_registry *, uint32_t) {}
inline const wl_registry_listener kRegistryListener = {onGlobal, onGlobalRemove};

// The manager global, bound once on a private event queue (the roundtrip never touches Qt's queue) and then moved back
// to the default queue; null when the compositor does not serve it.
inline wl_proxy *tagManager(wl_display *display)
{
    static wl_proxy *manager = nullptr;
    static bool tried = false;
    if (tried || !display)
        return manager;
    tried = true;
    wl_event_queue *queue = wl_display_create_queue(display);
    auto *wrapper = static_cast<wl_display *>(wl_proxy_create_wrapper(display));
    if (!queue || !wrapper) {
        if (wrapper)
            wl_proxy_wrapper_destroy(wrapper);
        if (queue)
            wl_event_queue_destroy(queue);
        return nullptr;
    }
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(wrapper), queue);
    wl_registry *registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);
    Binder binder;
    wl_registry_add_listener(registry, &kRegistryListener, &binder);
    wl_display_roundtrip_queue(display, queue);
    if (binder.name != 0) {
        manager = static_cast<wl_proxy *>(wl_registry_bind(registry, binder.name, &kManagerInterface, 1));
        if (manager)
            wl_proxy_set_queue(manager, nullptr);
    }
    wl_registry_destroy(registry);
    wl_event_queue_destroy(queue);
    return manager;
}

// Sends the tag for `toplevel`; false when there is no manager.
inline bool sendTag(::xdg_toplevel *toplevel, const QByteArray &tag)
{
    auto *wayland = qGuiApp ? qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>() : nullptr;
    wl_proxy *manager = wayland ? tagManager(wayland->display()) : nullptr;
    if (!manager || !toplevel)
        return false;
    wl_proxy_marshal_flags(manager, kOpSetToplevelTag, nullptr, wl_proxy_get_version(manager), 0, toplevel, tag.constData());
    return true;
}

} // namespace detail

// Install on the QGuiApplication before any window is created: `new ChromeTagger(&app)`.
class ChromeTagger : public QObject
{
public:
    explicit ChromeTagger(QObject *parent = nullptr)
        : QObject(parent)
    {
        if (qGuiApp)
            qGuiApp->installEventFilter(this);
    }

    // The role a window declared (QML property gfChromeRole), "" when it draws no chrome of its own.
    static QString roleOf(const QWindow *window) { return window ? window->property("gfChromeRole").toString() : QString(); }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() != QEvent::PlatformSurface || QGuiApplication::platformName() != QLatin1String("wayland"))
            return false;
        auto *surfaceEvent = static_cast<QPlatformSurfaceEvent *>(event);
        auto *window = qobject_cast<QWindow *>(watched);
        if (surfaceEvent->surfaceEventType() != QPlatformSurfaceEvent::SurfaceCreated || !window)
            return false;
        const QString role = roleOf(window);
        if (role.isEmpty())
            return false;
        auto *native = window->nativeInterface<QNativeInterface::Private::QWaylandWindow>();
        if (!native)
            return false;
        const QByteArray tag = role.toUtf8();
        const QPointer<QWindow> guard(window);
        // The toplevel exists already (Qt created it with the platform window) or is created right after: tag it as soon as
        // it does, which is before the first commit that maps the window.
        const auto tagNow = [native, tag]() {
            if (auto *toplevel = native->surfaceRole<::xdg_toplevel>()) {
                if (detail::sendTag(toplevel, tag))
                    qInfo("grassfield: window tagged '%s' (xdg-toplevel-tag)", tag.constData());
                else
                    qInfo("grassfield: no xdg-toplevel-tag manager: the compositor keeps its titlebar on this window");
                return true;
            }
            return false;
        };
        // A toplevel Qt creates again (the window hidden and shown) is a new object and gets its tag again.
        tagNow();
        connect(native, &QNativeInterface::Private::QWaylandWindow::surfaceRoleCreated, window, tagNow);
        return false;
    }
};

} // namespace grassfield::apps
