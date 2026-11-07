#pragma once

// Small compile-time compatibility layer for the Hyprland 0.56 and 0.57
// plugin APIs. CMake and build-direct.sh set GF_HYPRLAND_API_57 from the
// version.h belonging to the headers used for the build.
#ifndef GF_HYPRLAND_API_57
#define GF_HYPRLAND_API_57 0
#endif

#if GF_HYPRLAND_API_57
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/state/workspace/State.hpp>
#include <hyprland/src/state/workspace/Query.hpp>
#include <hyprland/src/state/workspace/Target.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/ipc/s1/S1.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#include <hyprland/src/desktop/view/window/WindowMetadata.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/window/WindowEffectsController.hpp>
#include <hyprland/src/render/transformer/TransformerList.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <functional>
#include <optional>
#include <string>
namespace gf {
    using HyprCtlCommand = IPC::Socket1::SCommand;
    using HyprCtlOutputFormat = IPC::Socket1::eOutputFormat;
    inline bool mapped(const PHLWINDOW& w) { return w && w->mapped(); }
    inline bool mapped(const PHLLS& l) { return l && l->mapped(); }
    inline bool visible(const PHLWORKSPACE& w) { return w && w->visible(); }
    inline bool pinned(const PHLWINDOW& w) { return w && (w->m_state & Desktop::View::WINDOW_STATE_PINNED); }
    inline bool floating(const PHLWINDOW& w) { return w && w->isFloating(); }
    inline bool x11(const PHLWINDOW& w) { return w && w->backend().isX11(); }
    inline bool overrideRedirect(const PHLWINDOW& w) { return w && w->backend().traits().overrideRedirect; }
    inline bool modal(const PHLWINDOW& w) { return w && w->backend().traits().modal; }
    inline bool noBorder(const PHLWINDOW& w) { return w && w->backend().traits().suggestsNoBorder; }
    inline bool shouldntFocus(const PHLWINDOW& w) { return w && w->shouldntFocus(); }
    inline PHLWINDOW parent(const PHLWINDOW& w) { return w ? w->backend().parent() : nullptr; }
    inline std::optional<std::string> xdgTag(const PHLWINDOW& w) { return w ? w->backend().metadata().tag : std::nullopt; }
    inline bool hasTransformers(const PHLWINDOW& w) { return w && w->effects().hasActiveTransformers(); }
    inline Vector2D surfaceGeometryOrigin(const PHLWINDOW& w) { return w ? w->backend().geometry().box.pos() : Vector2D{}; }
    inline bool mapped(const PHLLSREF& l) { const auto live = l.lock(); return live && live->mapped(); }
    inline const std::string& title(const PHLWINDOW& w) { return w->metadata().title(); }
    inline const std::string& appId(const PHLWINDOW& w) { return w->metadata().appID(); }
    inline Vector2D floatingOffset(const PHLWINDOW& w) { return w->presentation().floatingOffset(); }
    inline float rounding(const PHLWINDOW& w) { return w->presentation().rounding(); }
    inline float roundingPower(const PHLWINDOW& w) { return w->presentation().roundingPower(); }
    inline auto& windowAlpha(const PHLWINDOW& w, Desktop::View::eWindowAlpha key) { return w->presentation().alpha().get(key); }
    inline int64_t workspaceId(const PHLWORKSPACE& w) {
        const auto id = w->id();
        const auto* numbered = std::get_if<Workspace::SWorkspaceNumberedID>(&id);
        return numbered ? numbered->value : 0;
    }
    inline bool special(const PHLWORKSPACE& w) { return w && w->type() == Workspace::eWorkspaceType::SPECIAL; }
    inline auto workspaceSpace(const PHLWORKSPACE& w) { return w->space(); }
    inline const std::string& workspaceName(const PHLWORKSPACE& w) { return w->addressableName(); }
    inline PHLWORKSPACE findWorkspace(int64_t id) {
        const auto name = std::to_string(id);
        const State::Workspace::STarget target{.id = Workspace::SWorkspaceNumberedID{static_cast<uint32_t>(id)}, .address = name,
                                               .displayName = name, .type = Workspace::eWorkspaceType::NORMAL};
        return State::Workspace::state() ? State::Workspace::state()->find(target) : nullptr;
    }
    inline PHLWORKSPACE createWorkspace(int64_t id, const PHLMONITOR& monitor) {
        return State::Workspace::state()->createNumbered(Workspace::SWorkspaceNumberedID{static_cast<uint32_t>(id)}, monitor);
    }
    inline auto& exclusiveLayers() { return g_pInputManager->m_exclusiveKeyboardLSes; }
    using HyprCtlHandler = std::string (*)(HyprCtlOutputFormat, const std::string&) noexcept;
    inline SP<HyprCtlCommand> registerHyprCtl(HANDLE h, std::string name, HyprCtlHandler fn) {
        return HyprlandAPI::registerHyprCtlCommand(h, HyprCtlCommand{.name = std::move(name), .match = IPC::Socket1::COMMAND_MATCH_EXACT,
            .handler = [fn](const IPC::Socket1::SRequest& req) { return IPC::Socket1::SResponse(fn(req.format, req.command)); }});
    }
    inline void unregisterHyprCtl(HANDLE h, const SP<HyprCtlCommand>& command) { HyprlandAPI::unregisterHyprCtlCommand(h, command); }
    inline void postSocketEvent(std::string event, std::string data) {
        if (auto& socket = IPC::Socket2::sock(); socket)
            socket->postEvent(IPC::Socket2::SEvent{.event = std::move(event), .data = std::move(data)});
    }
}
#else
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/debug/HyprCtl.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <functional>
#include <string>
namespace gf {
    using HyprCtlCommand = SHyprCtlCommand;
    using HyprCtlOutputFormat = eHyprCtlOutputFormat;
    inline bool mapped(const PHLWINDOW& w) { return w && w->m_isMapped; }
    inline bool mapped(const PHLLS& l) { return l && l->m_mapped; }
    inline bool visible(const PHLWORKSPACE& w) { return w && w->isVisible(); }
    inline bool pinned(const PHLWINDOW& w) { return w && w->m_pinned; }
    inline bool floating(const PHLWINDOW& w) { return w && w->m_isFloating; }
    inline bool x11(const PHLWINDOW& w) { return w && w->m_isX11; }
    inline bool overrideRedirect(const PHLWINDOW& w) { return w && w->isX11OverrideRedirect(); }
    inline bool modal(const PHLWINDOW& w) { return w && w->isModal(); }
    inline bool noBorder(const PHLWINDOW& w) { return w && w->m_X11DoesntWantBorders; }
    inline bool shouldntFocus(const PHLWINDOW& w) { return w && w->m_X11ShouldntFocus; }
    inline PHLWINDOW parent(const PHLWINDOW& w) { return w ? w->parent() : nullptr; }
    inline std::optional<std::string> xdgTag(const PHLWINDOW& w) { return w ? w->xdgTag() : std::nullopt; }
    inline bool hasTransformers(const PHLWINDOW& w) { return w && !w->m_transformers.empty(); }
    inline Vector2D surfaceGeometryOrigin(const PHLWINDOW& w) {
        const auto xdg = w ? w->m_xdgSurface.lock() : nullptr;
        return xdg ? xdg->m_current.geometry.pos() : Vector2D{};
    }
    inline bool mapped(const PHLLSREF& l) { const auto live = l.lock(); return live && live->m_mapped; }
    inline const std::string& title(const PHLWINDOW& w) { return w->m_title; }
    inline const std::string& appId(const PHLWINDOW& w) { return w->m_class; }
    inline Vector2D floatingOffset(const PHLWINDOW& w) { return w->m_floatingOffset; }
    inline float rounding(const PHLWINDOW& w) { return w->rounding(); }
    inline float roundingPower(const PHLWINDOW& w) { return w->roundingPower(); }
    inline auto& windowAlpha(const PHLWINDOW& w, Desktop::View::eWindowAlpha key) { return w->alpha(key); }
    inline int64_t workspaceId(const PHLWORKSPACE& w) { return w ? w->m_id : 0; }
    inline bool special(const PHLWORKSPACE& w) { return w && w->m_isSpecialWorkspace; }
    inline auto workspaceSpace(const PHLWORKSPACE& w) { return w->m_space; }
    inline const std::string& workspaceName(const PHLWORKSPACE& w) { return w->m_name; }
    inline PHLWORKSPACE findWorkspace(int64_t id) { return State::workspaceState()->query().id(id).run(); }
    inline PHLWORKSPACE createWorkspace(int64_t id, const PHLMONITOR& monitor) { return State::workspaceState()->create(id, monitor->m_id); }
    inline auto& exclusiveLayers() { return g_pInputManager->m_exclusiveLSes; }
    using HyprCtlHandler = std::string (*)(HyprCtlOutputFormat, const std::string&) noexcept;
    inline SP<HyprCtlCommand> registerHyprCtl(HANDLE h, std::string name, HyprCtlHandler fn) {
        return HyprlandAPI::registerHyprCtlCommand(h, HyprCtlCommand{.name = std::move(name), .exact = true, .fn = fn});
    }
    inline void unregisterHyprCtl(HANDLE h, const SP<HyprCtlCommand>& command) { HyprlandAPI::unregisterHyprCtlCommand(h, command); }
    inline void postSocketEvent(std::string event, std::string data) {
        if (g_pEventManager)
            g_pEventManager->postEvent(SHyprIPCEvent{.event = std::move(event), .data = std::move(data)});
    }
}
#endif
