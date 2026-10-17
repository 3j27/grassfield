#include "Minimize.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
#include "core/Protocol.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/state/WorkspaceQuery.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <format>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace mz = gf::minimize;

namespace {
    // The hidden state. Same name as the shell's fallback (shell/platform/Compositor.qml minimizedWorkspace).
    constexpr std::string_view MINIMIZED_WORKSPACE = "special:minimized";

    // Completes animations whose frames stopped (no monitor rendered): longer than any animation.
    constexpr auto WATCHDOG_DELAY = std::chrono::milliseconds(450);

    struct SAnimation {
        mz::Kind                 kind = mz::Kind::Minimize;
        PHLWINDOWREF             window;
        uint64_t                 address = 0;
        SP<Render::IFramebuffer> snapshot;
        mz::SSnapshotGeometry    geometry; // visible box (titlebar + border + surface) in the snapshot
        mz::Box                  full;     // with every decoration extent (shadow): what gets damaged
        mz::Box                  from;
        mz::Box                  to;
        Time::steady_tp          start;
        mz::Frame                frame;
        mz::Box                  damaged; // last damaged visual box (layout)
    };

    struct SMinimizeState {
        bool                             ready = false;
        std::vector<SAnimation>          animations;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SMinimizeState& st() {
        static SMinimizeState s;
        return s;
    }

    std::string hexAddress(uint64_t address) {
        return std::format("{:x}", address);
    }

    // minimized / restored: two values of one per-window state, coalesced under one key (spec FR24).
    void postState(mz::Kind kind, uint64_t address) {
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::MinimizeState, .id = address},
                           kind == mz::Kind::Minimize ? gf::gfc::minimizedJson(hexAddress(address)) : gf::gfc::restoredJson(hexAddress(address)));
    }

    mz::Box toBox(const CBox& b) {
        return mz::Box{b.x, b.y, b.w, b.h};
    }

    CBox toCBox(const mz::Box& b) {
        return CBox{b.x, b.y, b.w, b.h};
    }

    // The address is compared, never dereferenced.
    PHLWINDOW windowByAddress(uint64_t address) {
        if (!Desktop::windowState())
            return nullptr;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (w && reinterpret_cast<uintptr_t>(w.get()) == address)
                return w;
        }
        return nullptr;
    }

    bool onMinimizedWorkspace(const PHLWINDOW& w) {
        return w->m_workspace && w->m_workspace->m_isSpecialWorkspace && w->m_workspace->m_name == MINIMIZED_WORKSPACE;
    }

    // Surface box plus the reserved decoration extents (titlebar, border): what the user sees as the window.
    mz::Box visibleBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::RESERVED_EXTENTS));
        return toBox(box);
    }

    mz::Box fullBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::FULL_EXTENTS | Desktop::View::RESERVED_EXTENTS));
        return toBox(box.expand(2.0));
    }

    // Removes and returns the window's running animation (at most one per window).
    std::optional<SAnimation> takeAnimation(const PHLWINDOW& w) {
        auto&      all = st().animations;
        const auto it  = std::ranges::find_if(all, [&w](const SAnimation& a) { return a.window.lock() == w; });
        if (it == all.end())
            return std::nullopt;
        SAnimation a = std::move(*it);
        all.erase(it);
        return a;
    }

    // Snapshots are GL framebuffers: delete them with Hyprland's context current. Never called while a frame
    // is being built (only from Lua calls, render.preChecks, the watchdog and unload).
    void releaseSnapshot(SP<Render::IFramebuffer>& fb) {
        if (!fb)
            return;
        if (g_pHyprRenderer && g_pHyprRenderer->type() == Render::IHyprRenderer::RT_GL && Render::GL::g_pHyprOpenGL)
            Render::GL::g_pHyprOpenGL->makeEGLCurrent();
        fb.reset();
    }

    SP<Render::IFramebuffer> takeSnapshot(const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return nullptr;
        // nullptr when Hyprland would not render the window now (hidden workspace, no monitor).
        auto fb = g_pHyprRenderer->makeSnapshotFB(w);
        if (!fb || !fb->getTexture())
            return nullptr;
        return fb;
    }

    void damage(SAnimation& a) {
        if (!g_pHyprRenderer)
            return;
        const mz::Box visual = mz::mapBox(a.full, a.geometry.visible, a.frame.box);
        if (a.damaged.w > 0 && a.damaged.h > 0)
            g_pHyprRenderer->damageBox(toCBox(a.damaged));
        g_pHyprRenderer->damageBox(toCBox(visual));
        a.damaged = visual;
    }

    // The window, transparent while its restore animation runs, becomes visible again.
    void showWindow(const PHLWINDOW& w) {
        auto& fadeIn = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (fadeIn)
            fadeIn->setValueAndWarp(1.F);
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
    }

    // Ends an animation: final state, snapshot dropped, optional event. `a` is erased by the caller.
    void complete(SAnimation& a, bool postEvent) {
        if (g_pHyprRenderer && a.damaged.w > 0)
            g_pHyprRenderer->damageBox(toCBox(a.damaged));
        const auto w = a.window.lock();
        if (a.kind == mz::Kind::Restore && w)
            showWindow(w);
        releaseSnapshot(a.snapshot);
        if (postEvent && w)
            postState(a.kind, a.address);
    }

    void completeAll(bool postEvents) {
        auto animations = std::exchange(st().animations, {});
        for (auto& a : animations)
            complete(a, postEvents);
    }

    // The window closed (or unmapped) mid-animation: drop the visual, no event.
    void cancelFor(const PHLWINDOW& w) {
        auto& all = st().animations;
        for (auto it = all.begin(); it != all.end();) {
            const auto aw = it->window.lock();
            if (!aw || aw == w) {
                if (g_pHyprRenderer && it->damaged.w > 0)
                    g_pHyprRenderer->damageBox(toCBox(it->damaged));
                releaseSnapshot(it->snapshot);
                it = all.erase(it);
            } else
                ++it;
        }
    }

    // One step of every animation; called before each monitor frame (render.preChecks, like Hyprland's
    // Animation::mgr()->frameTick()) and by the watchdog. Damages the old and new boxes, which also schedules
    // the next frame on the monitors they touch.
    void tick() {
        auto& all = st().animations;
        if (all.empty())
            return;
        const auto now = Time::steadyNow();
        for (auto it = all.begin(); it != all.end();) {
            const auto w = it->window.lock();
            if (!w || !w->m_isMapped) {
                if (g_pHyprRenderer && it->damaged.w > 0)
                    g_pHyprRenderer->damageBox(toCBox(it->damaged));
                releaseSnapshot(it->snapshot);
                it = all.erase(it);
                continue;
            }
            const double elapsedMs = std::chrono::duration<double, std::milli>(now - it->start).count();
            it->frame              = mz::frameAt(it->kind, it->from, it->to, elapsedMs);
            damage(*it);
            if (it->frame.done) {
                complete(*it, true);
                it = all.erase(it);
            } else
                ++it;
        }
    }

    void armWatchdog() {
        auto& s = st();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("minimize watchdog", [] {
                        tick();
                        if (!st().animations.empty() && st().watchdog)
                            st().watchdog->updateTimeout(WATCHDOG_DELAY);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        s.watchdog->updateTimeout(WATCHDOG_DELAY);
    }

    void startAnimation(SAnimation&& a) {
        a.start = Time::steadyNow();
        a.frame = mz::frameAt(a.kind, a.from, a.to, 0.0);
        damage(a);
        st().animations.push_back(std::move(a));
        armWatchdog();
    }

    // Draws every animation that touches the monitor being rendered. RENDER_POST_WINDOWS: after the windows,
    // before the top layers (menu bar, Dock); not emitted while the session is locked (no window content on
    // the lock screen).
    void draw() {
        auto& all = st().animations;
        if (all.empty() || !g_pHyprRenderer)
            return;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return;
        const mz::Box monBox{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
        for (const auto& a : all) {
            if (!a.snapshot || a.frame.alpha <= 0.F)
                continue;
            const auto tex = a.snapshot->getTexture();
            if (!tex)
                continue;
            const mz::Box visual = mz::mapBox(a.full, a.geometry.visible, a.frame.box);
            if (!mz::intersects(visual, monBox))
                continue;
            const mz::Box texBox = mz::textureBox(a.geometry, a.frame.box, mon->m_position.x, mon->m_position.y, mon->m_scale);

            CTexPassElement::SRenderData data;
            data.tex          = tex;
            data.box          = toCBox(texBox);
            data.a            = a.frame.alpha;
            data.flipEndFrame = true; // framebuffer texture, as Hyprland draws its fadeouts
            data.clipBox      = toCBox(visual).translate(-mon->m_position).scale(mon->m_scale).round();
            g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(std::move(data)));
        }
    }

    PHLWORKSPACE minimizedWorkspace() {
        const auto [id, name, isAutoID] = getWorkspaceIDNameFromString(std::string{MINIMIZED_WORKSPACE});
        if (id == WORKSPACE_INVALID)
            return nullptr;
        auto ws = State::workspaceState()->query().id(id).run();
        if (!ws) {
            const auto mon = Desktop::focusState()->monitor();
            if (mon)
                ws = State::workspaceState()->create(id, mon->m_id, name, false);
        }
        return ws;
    }

    // Moves the window to special:minimized without following it. Hyprland fades a window out in place when it
    // leaves a visible workspace; the snapshot animation replaces that fade, so it is completed at once.
    bool hideOnMinimized(const PHLWINDOW& w) {
        const auto ws = minimizedWorkspace();
        if (!ws) {
            gf::log(Log::WARN, "minimize: cannot resolve {}", MINIMIZED_WORKSPACE);
            return false;
        }
        if (const auto result = Config::Actions::moveToWorkspace(ws, true, w); !result) {
            gf::log(Log::WARN, "minimize: move to {} failed: {}", MINIMIZED_WORKSPACE, result.error().message);
            return false;
        }
        if (auto& fadeOut = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_TO_WORKSPACE); fadeOut && fadeOut->isBeingAnimated())
            fadeOut->warp();
        return onMinimizedWorkspace(w);
    }

    std::vector<mz::Box> monitorBoxes() {
        std::vector<mz::Box> out;
        if (!State::monitorState())
            return out;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m)
                out.push_back(mz::Box{m->m_position.x, m->m_position.y, m->m_size.x, m->m_size.y});
        }
        return out;
    }

    mz::SSnapshotGeometry snapshotGeometry(const PHLWINDOW& w, const PHLMONITOR& mon) {
        return mz::SSnapshotGeometry{.visible      = visibleBox(w),
                                     .monitorX     = mon->m_position.x,
                                     .monitorY     = mon->m_position.y,
                                     .monitorScale = mon->m_scale,
                                     .texW         = mon->m_transformedSize.x,
                                     .texH         = mon->m_transformedSize.y};
    }
} // namespace

namespace gf::minimizer {

    bool start() {
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("minimize tick", [] { tick(); }); }));
        l.push_back(ev.render.stage.listen([](eRenderStage stage) {
            if (stage == RENDER_POST_WINDOWS)
                gf::guarded("minimize draw", [] { draw(); });
        }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("minimize window.close", [&] { cancelFor(w); }); }));
        // Monitor changes: positions and scales captured with the snapshots are stale; finish at once.
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("minimize monitor.removed", [] { completeAll(true); }); }));
        l.push_back(ev.monitor.layoutChanged.listen([] { gf::guarded("minimize monitor.layoutChanged", [] { completeAll(true); }); }));
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.listeners.clear();
        completeAll(false);
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
    }

    bool ready() {
        return st().ready;
    }

    std::optional<mz::Box> validTarget(const mz::Box& rect) {
        const auto monitors = monitorBoxes();
        if (!mz::isValidTarget(rect, monitors))
            return std::nullopt;
        return rect;
    }

    void minimize(uint64_t address, std::optional<mz::Box> target) {
        const auto w = windowByAddress(address);
        if (!w || !w->m_isMapped) {
            gf::logRequest(Log::WARN, "minimize: no mapped window {:x}", address);
            return;
        }
        if (onMinimizedWorkspace(w)) {
            gf::logRequest(Log::DEBUG, "minimize: window {:x} is already minimized", address);
            return;
        }

        // A restore still animating: the new animation starts where that one is.
        std::optional<mz::Box> from;
        if (auto running = takeAnimation(w)) {
            if (running->kind == mz::Kind::Restore)
                from = running->frame.box;
            complete(*running, true);
        }

        SP<Render::IFramebuffer> snapshot;
        mz::SSnapshotGeometry    geometry;
        mz::Box                  full;
        const auto               mon = w->m_monitor.lock();
        if (target && mon) {
            snapshot = takeSnapshot(w);
            geometry = snapshotGeometry(w, mon);
            full     = fullBox(w);
        }

        if (!hideOnMinimized(w)) {
            releaseSnapshot(snapshot);
            return;
        }
        if (!snapshot || !target) { // no snapshot without a target: no animation
            releaseSnapshot(snapshot);
            postState(mz::Kind::Minimize, address);
            return;
        }
        startAnimation(SAnimation{.kind     = mz::Kind::Minimize,
                                  .window   = w,
                                  .address  = address,
                                  .snapshot = std::move(snapshot),
                                  .geometry = geometry,
                                  .full     = full,
                                  .from     = from.value_or(geometry.visible),
                                  .to       = mz::fitInside(geometry.visible, *target),
                                  .start    = {},
                                  .frame    = {},
                                  .damaged  = {}});
    }

    void restore(uint64_t address, std::optional<mz::Box> target) {
        const auto w = windowByAddress(address);
        if (!w || !w->m_isMapped) {
            gf::logRequest(Log::WARN, "restore: no mapped window {:x}", address);
            return;
        }
        if (auto running = takeAnimation(w))
            complete(*running, true);
        if (!onMinimizedWorkspace(w)) {
            gf::logRequest(Log::DEBUG, "restore: window {:x} is not minimized", address);
            return;
        }

        const auto focusMon = Desktop::focusState()->monitor();
        const auto ws       = focusMon ? focusMon->m_activeWorkspace : nullptr;
        if (!ws) {
            gf::log(Log::WARN, "restore: no active workspace");
            return;
        }
        if (const auto result = Config::Actions::moveToWorkspace(ws, true, w); !result || onMinimizedWorkspace(w)) {
            gf::log(Log::WARN, "restore: move of {:x} to workspace {} failed", address, ws->m_name);
            return;
        }

        // Hyprland fades a window in when it arrives on a visible workspace and may move it there with an
        // animation: settle both so the snapshot shows the window at its place, fully opaque.
        w->positionAnimation()->warp();
        w->sizeAnimation()->warp();
        auto& fadeIn = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (fadeIn && fadeIn->isBeingAnimated())
            fadeIn->warp();

        if (const auto focus = Desktop::focusState(); focus)
            focus->fullWindowFocus(w, Desktop::FOCUS_REASON_OTHER);
        if (const auto result = Config::Actions::alterZOrder("top", w); !result)
            gf::log(Log::WARN, "restore: raise failed: {}", result.error().message);

        const auto mon      = w->m_monitor.lock();
        auto       snapshot = target && mon ? takeSnapshot(w) : nullptr;
        if (!snapshot || !target) {
            releaseSnapshot(snapshot);
            postState(mz::Kind::Restore, address);
            return;
        }

        // Transparent until the snapshot has grown back to its place (showWindow in complete()).
        if (fadeIn)
            fadeIn->setValueAndWarp(0.F);
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);

        const auto geometry = snapshotGeometry(w, mon);
        startAnimation(SAnimation{.kind     = mz::Kind::Restore,
                                  .window   = w,
                                  .address  = address,
                                  .snapshot = std::move(snapshot),
                                  .geometry = geometry,
                                  .full     = fullBox(w),
                                  .from     = mz::fitInside(geometry.visible, *target),
                                  .to       = geometry.visible,
                                  .start    = {},
                                  .frame    = {},
                                  .damaged  = {}});
    }

} // namespace gf::minimizer
