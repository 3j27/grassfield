#include "Stages.hpp"

#include "Ipc.hpp"
#include "Overview.hpp"
#include "Plugin.hpp"
#include "WindowTransform.hpp"
#include "core/EventThrottle.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace st = gf::stages;
namespace tf = gf::transform;

namespace {
    // Layer namespace of the shell's strip surface (Top or Overlay layer, input over the tiles). Thumbnails are drawn only
    // where it covers them: a click on a thumbnail must reach the shell, never a window hidden under the drawing.
    constexpr std::string_view STRIP_NAMESPACE = "grassfield-stages";

    // The plugin's own input block reason: a bit Hyprland 0.56.2 does not use (INPUT_BLOCK_GROUP_INACTIVE 1 << 0,
    // MONOCLE_INACTIVE 1 << 1, BELOW_FULLSCREEN 1 << 2). CWindow::acceptsInput() is false while any reason is set:
    // CViewHitTester::windowAt then skips the window for pointer focus, clicks, titlebar presses and hovers.
    constexpr uint8_t INPUT_BLOCK_STAGES_BIT = 1U << 6;
    const auto        INPUT_BLOCK_STAGES     = static_cast<Desktop::View::eWindowInputBlockReason>(INPUT_BLOCK_STAGES_BIT);

    // Ends animations whose frames stopped (no monitor rendered): checked this long after the expected end.
    constexpr auto WATCHDOG_SLACK = std::chrono::milliseconds(150);

    // An active window closer than this to the strip's tiles counts as overlapping it (the shell then hides the strip).
    constexpr double OVERLAP_MARGIN = 8;

    class CStageTransformer final : public Render::IWindowTransformer {
      public:
        SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override;
    };

    // A window Stages draws or has drawn: its transformer, input block and animation.
    struct SWin {
        PHLWINDOWREF           window;
        uint64_t               address     = 0;
        CStageTransformer*     transformer = nullptr; // owned by window->m_transformers; compared, never freed here
        bool                   blocked     = false;   // INPUT_BLOCK_STAGES set by this plugin
        bool                   inStrip     = false;   // its target is a strip position (tile or off screen)
        std::optional<st::Box> from;                  // nullopt: its live surface box
        std::optional<st::Box> to;                    // nullopt: its live surface box (shown normally)
        st::Box                rect;                  // where its surface box is drawn at the last tick
        st::Box                damaged;               // last damaged visual box (layout, with every decoration)
        std::optional<st::Box> thumb;                 // its place in its tile when the strip is shown (events)
    };

    struct SStrip {
        std::string          monitor;
        PHLMONITORREF        mon;
        std::vector<st::Box> tiles;
        bool                 hidden  = false;
        bool                 overlap = false;
    };

    struct SSpace {
        st::WorkspaceId       id = 0;
        st::CWorkspaceStages  model;
    };

    struct SStagesState {
        bool                             ready   = false;
        bool                             enabled = false; // the feature flag (config stagesEnabled)
        bool                             on      = false; // the shell turned Stages on (op on) and has not turned it off
        st::StageId                      nextId  = 1;
        std::vector<SSpace>              spaces;
        std::vector<SWin>                wins;
        std::vector<SStrip>              strips;
        double                           durationMs = 0; // of swaps (from op on)
        st::Curve                        curve;
        bool                             animating = false;
        Time::steady_tp                  start;
        double                           animMs = 0;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog;  // shared: CEventLoopManager holds a strong reference too
        std::optional<uint64_t>          syncLater; // doLater sequence of a pending sync (its callback is code of this library)
        std::optional<st::WorkspaceId>   refocusSpace; // after a close: the active stage of this workspace takes the keyboard
        PHLWINDOWREF                     focusLater;   // the window the latest activate / merge / move request made key
        bool                             warnedNoBuffer = false;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SStagesState& S() {
        static SStagesState s;
        return s;
    }

    uint64_t addressOf(const PHLWINDOW& w) {
        return reinterpret_cast<uintptr_t>(w.get());
    }

    // The address is compared, never dereferenced.
    PHLWINDOW windowByAddress(uint64_t address) {
        if (!Desktop::windowState())
            return nullptr;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (w && addressOf(w) == address)
                return w;
        }
        return nullptr;
    }

    PHLMONITOR monitorByName(std::string_view name) {
        if (!State::monitorState())
            return nullptr;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_name == name)
                return m;
        }
        return nullptr;
    }

    st::Box monitorBox(const PHLMONITOR& mon) {
        return st::Box{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
    }

    // The monitor that shows this workspace as its active workspace, if any.
    PHLMONITOR shownOn(st::WorkspaceId id) {
        if (!State::monitorState())
            return nullptr;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_activeWorkspace && m->m_activeWorkspace->m_id == id)
                return m;
        }
        return nullptr;
    }

    bool showsFullscreen(const PHLWORKSPACE& ws) {
        const auto& fullscreen = Fullscreen::controller();
        return ws && fullscreen && fullscreen->getFullscreenModes(ws).internal == Fullscreen::FSMODE_FULLSCREEN;
    }

    // Windows Stages manages: mapped, visible, floating (ADR-0002 floating-first; tiled windows are left to the layout),
    // not pinned (drawn on every workspace), on a regular workspace (minimized windows live on special:minimized), not an
    // X11 override-redirect window. A full-screen window keeps its stage (its workspace's strip is then hidden).
    bool manageable(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || w->isHidden() || !w->m_isFloating || w->m_pinned || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
            return false;
        return !(w->m_isX11 && w->isX11OverrideRedirect());
    }

    bool fullscreenNow(const PHLWINDOW& w) {
        const auto& fullscreen = Fullscreen::controller();
        return fullscreen && fullscreen->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN;
    }

    st::WindowInfo infoOf(const PHLWINDOW& w) {
        return st::WindowInfo{.id = addressOf(w), .app = w->m_class};
    }

    SSpace* spaceOf(st::WorkspaceId id) {
        auto& all = S().spaces;
        const auto it = std::ranges::find_if(all, [id](const SSpace& sp) { return sp.id == id; });
        return it == all.end() ? nullptr : &*it;
    }

    SSpace& ensureSpace(st::WorkspaceId id) {
        if (auto* sp = spaceOf(id))
            return *sp;
        S().spaces.push_back(SSpace{.id = id, .model = {}});
        return S().spaces.back();
    }

    SSpace* spaceHolding(uint64_t address) {
        for (auto& sp : S().spaces) {
            if (sp.model.contains(address))
                return &sp;
        }
        return nullptr;
    }

    SSpace* spaceWithStage(st::StageId stage) {
        for (auto& sp : S().spaces) {
            if (std::ranges::any_of(sp.model.stages(), [stage](const st::Stage& s) { return s.id == stage; }))
                return &sp;
        }
        return nullptr;
    }

    SWin* winOf(uint64_t address) {
        auto&      all = S().wins;
        const auto it  = std::ranges::find_if(all, [address](const SWin& e) { return e.address == address; });
        return it == all.end() ? nullptr : &*it;
    }

    SStrip* stripOn(const PHLMONITOR& mon) {
        auto&      all = S().strips;
        const auto it  = std::ranges::find_if(all, [&mon](const SStrip& s) { return s.mon.lock() == mon; });
        return it == all.end() ? nullptr : &*it;
    }

    PHLLS stripSurfaceOn(const PHLMONITOR& mon) {
        if (!Desktop::layerState() || !mon)
            return nullptr;
        for (const auto& ls : Desktop::layerState()->layers()) {
            if (ls && ls->m_mapped && ls->m_namespace == STRIP_NAMESPACE && ls->m_monitor.lock() == mon)
                return ls;
        }
        return nullptr;
    }

    // The strip surface's input region covers the tile (its corners and centre; an infinite region covers everything).
    bool inputCovers(const PHLLS& ls, const st::Box& tile) {
        const auto surface = ls->resource();
        if (!surface)
            return false;
        if (surface->m_current.inputIsInfinite)
            return true;
        const double                  x = tile.x - ls->m_geometry.x, y = tile.y - ls->m_geometry.y;
        const std::array<Vector2D, 5> points{Vector2D{x + 1, y + 1}, Vector2D{x + tile.w - 1, y + 1}, Vector2D{x + 1, y + tile.h - 1}, Vector2D{x + tile.w - 1, y + tile.h - 1},
                                             Vector2D{x + (tile.w / 2), y + (tile.h / 2)}};
        return std::ranges::all_of(points, [&surface](const Vector2D& p) { return surface->m_current.input.containsPoint(p); });
    }

    // ---- events ----

    void post(st::Reason reason = st::Reason::None) {
        auto&                         s = S();
        std::vector<st::EventMonitor> monitors;
        if (s.on) {
            for (const auto& strip : s.strips) {
                const auto mon = strip.mon.lock();
                if (!mon || !mon->m_activeWorkspace)
                    continue;
                st::EventMonitor m;
                m.monitor   = strip.monitor;
                m.workspace = mon->m_activeWorkspace->m_id;
                m.hidden    = strip.hidden;
                m.overlap   = strip.overlap;
                if (const auto* sp = spaceOf(m.workspace)) {
                    m.active          = sp->model.active();
                    const auto& order = sp->model.stages();
                    for (size_t k = 0; k < order.size(); ++k) {
                        st::EventStage es;
                        es.id   = order[k].id;
                        es.slot = (k > 0 && k - 1 < strip.tiles.size()) ? static_cast<int>(k - 1) : -1;
                        for (const auto id : order[k].windows) {
                            const auto* e = winOf(id);
                            es.windows.push_back(st::EventWindow{.id = id, .thumb = es.slot >= 0 && e ? e->thumb : std::nullopt});
                        }
                        m.stages.push_back(std::move(es));
                    }
                }
                monitors.push_back(std::move(m));
            }
        }
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Stages, .id = 0}, st::eventJson(s.on, monitors, reason));
    }

    // ---- drawing ----

    void damage(SWin& e, const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return;
        const st::Box box = tf::visualBox(w, e.rect);
        for (const auto& b : gf::overview::damageStep(e.damaged, box))
            g_pHyprRenderer->damageBox(tf::toCBox(b));
        e.damaged = box;
    }

    CStageTransformer* attach(const PHLWINDOW& w) {
        auto  transformer = makeUnique<CStageTransformer>();
        auto* raw         = transformer.get();
        w->m_transformers.emplace_back(std::move(transformer));
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
        return raw;
    }

    // Back to normal rendering (the transformer leaves the window; a destroyed window took it along).
    void detach(SWin& e) {
        if (g_pHyprRenderer && tf::hasArea(e.damaged))
            g_pHyprRenderer->damageBox(tf::toCBox(e.damaged));
        const auto w = e.window.lock();
        if (w && e.transformer) {
            std::erase_if(w->m_transformers, [&e](const UP<Render::IWindowTransformer>& t) { return t.get() == e.transformer; });
            if (g_pHyprRenderer)
                g_pHyprRenderer->damageWindow(w);
        }
        e.transformer = nullptr;
        e.damaged     = {};
    }

    void setBlocked(SWin& e, bool blocked) {
        const auto w = e.window.lock();
        if (w && e.blocked != blocked)
            w->setInputBlocked(INPUT_BLOCK_STAGES, blocked);
        e.blocked = blocked && w;
    }

    // Drops an entry now: shown normally, input unblocked.
    void release(SWin& e) {
        setBlocked(e, false);
        detach(e);
    }

    void tick();

    void armWatchdog() {
        auto& s = S();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("stages watchdog", [] {
                        tick();
                        const auto& s = S();
                        if (s.animating && s.watchdog)
                            s.watchdog->updateTimeout(WATCHDOG_SLACK);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        s.watchdog->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::duration<double, std::milli>(s.animMs)) + WATCHDOG_SLACK);
    }

    // One animation step (render.preChecks, where Hyprland ticks its own animations, and the watchdog). At the end, windows
    // shown normally again lose their transformer, and entries of windows Stages no longer manages are dropped.
    void tick() {
        auto& s = S();
        if (!s.animating)
            return;
        const double elapsedMs = std::chrono::duration<double, std::milli>(Time::steadyNow() - s.start).count();
        const double t         = gf::overview::progress(elapsedMs, s.animMs);
        const double e         = gf::overview::eased(s.curve, t);
        for (auto it = s.wins.begin(); it != s.wins.end();) {
            const auto w = it->window.lock();
            if (!w) {
                detach(*it);
                it = s.wins.erase(it);
                continue;
            }
            if (it->transformer) {
                it->rect = gf::overview::interpolate(it->from, it->to, tf::surfaceBox(w), e);
                damage(*it, w);
            }
            ++it;
        }
        if (t < 1.0)
            return;
        s.animating = false;
        for (auto it = s.wins.begin(); it != s.wins.end();) {
            it->from = it->to;
            if (!it->to) {
                detach(*it);
                if (!it->inStrip && !it->blocked) {
                    it = s.wins.erase(it); // shown normally: nothing left to track
                    continue;
                }
            }
            ++it;
        }
    }

    void startAnimation(double durationMs) {
        auto& s     = S();
        s.animating = true;
        s.start     = Time::steadyNow();
        s.animMs    = durationMs;
        for (auto& e : s.wins) {
            if (const auto w = e.window.lock(); w && e.transformer) {
                e.rect = gf::overview::interpolate(e.from, e.to, tf::surfaceBox(w), 0.0);
                damage(e, w);
            }
        }
        if (durationMs <= 0)
            tick(); // no animation (Reduce Motion): the end state now
        else
            armWatchdog();
    }

    // Computes every managed window's target from the model and the strips, then applies it: live windows unblocked
    // first, `focus` focused, strip windows blocked and transformed, and one animation from where each window is drawn
    // now. The stacking order is Hyprland's (CWindowState::raise would also allow a window over full-screen ones).
    void retarget(double durationMs, const PHLWINDOW& focus = nullptr) {
        auto& s = S();
        struct STarget {
            PHLWINDOW              w;
            bool                   inStrip = false;
            std::optional<st::Box> to;
            std::optional<st::Box> thumb;
        };
        std::vector<STarget> targets;
        if (s.on) {
            for (const auto& sp : s.spaces) {
                const auto  mon   = shownOn(sp.id);
                const auto& order = sp.model.stages();
                if (!mon) {
                    // Not shown on any monitor (switched away): its windows stay as they are drawn (Hyprland does not render
                    // them; a switch back, and the workspace slide, find them in place).
                    for (const auto& stage : order) {
                        for (const auto id : stage.windows) {
                            const auto  w = windowByAddress(id);
                            const auto* e = w ? winOf(id) : nullptr;
                            if (w)
                                targets.push_back(e ? STarget{.w = w, .inStrip = e->inStrip, .to = e->to, .thumb = e->thumb} :
                                                      STarget{.w = w, .inStrip = false, .to = std::nullopt, .thumb = std::nullopt});
                        }
                    }
                    continue;
                }
                SStrip*    strip = stripOn(mon);
                const bool fs    = showsFullscreen(mon->m_activeWorkspace);
                for (size_t k = 0; k < order.size(); ++k) {
                    std::vector<PHLWINDOW> ws;
                    std::vector<st::Box>   surfaces;
                    for (const auto id : order[k].windows) {
                        if (const auto w = windowByAddress(id)) {
                            ws.push_back(w);
                            surfaces.push_back(tf::surfaceBox(w));
                        }
                    }
                    if (!strip || k == 0) { // the active stage, or a workspace whose monitor has no strip: shown normally
                        for (const auto& w : ws)
                            targets.push_back(STarget{.w = w, .inStrip = false, .to = std::nullopt, .thumb = std::nullopt});
                        continue;
                    }
                    const size_t slot    = k - 1;
                    const bool   hasTile = slot < strip->tiles.size();
                    const auto   rects   = st::thumbRects(hasTile ? strip->tiles[slot] : strip->tiles.back(), surfaces);
                    const double shift   = (strip->hidden || !hasTile || fs) ? st::hiddenShift(strip->tiles, monitorBox(mon)) : 0.0;
                    for (size_t i = 0; i < ws.size(); ++i) {
                        const st::Box r = rects[i];
                        targets.push_back(STarget{.w       = ws[i],
                                                  .inStrip = true,
                                                  .to      = st::Box{r.x + shift, r.y, r.w, r.h},
                                                  .thumb   = hasTile ? std::optional<st::Box>{r} : std::nullopt});
                    }
                }
            }
        }

        // Windows no longer targeted (unmanaged, Stages off): back to live.
        for (auto& e : s.wins) {
            const bool targeted = std::ranges::any_of(targets, [&e](const STarget& t) { return addressOf(t.w) == e.address; });
            if (!targeted) {
                e.inStrip = false;
                e.to      = std::nullopt;
                e.thumb   = std::nullopt;
            }
        }
        for (const auto& t : targets) {
            SWin* e = winOf(addressOf(t.w));
            if (!e) {
                if (!t.inStrip)
                    continue; // shown normally and never drawn by Stages: nothing to track
                s.wins.push_back(SWin{.window = t.w, .address = addressOf(t.w), .transformer = nullptr, .blocked = false, .inStrip = false, .from = std::nullopt,
                                      .to = std::nullopt, .rect = {}, .damaged = {}, .thumb = std::nullopt});
                e = &s.wins.back();
            }
            e->inStrip = t.inStrip;
            e->to      = t.to;
            e->thumb   = t.thumb;
        }

        // Unblock first, then focus, then block: blocking a focused window would make Hyprland clear the keyboard focus.
        for (auto& e : s.wins) {
            if (!e.inStrip)
                setBlocked(e, false);
        }
        if (focus && focus->m_isMapped && Desktop::focusState())
            Desktop::focusState()->fullWindowFocus(focus, Desktop::FOCUS_REASON_OTHER);
        for (auto& e : s.wins) {
            if (!e.inStrip)
                continue;
            setBlocked(e, true);
            if (!e.transformer) {
                if (const auto w = e.window.lock()) {
                    e.from        = std::nullopt; // from its live box
                    e.transformer = attach(w);
                }
            } else
                e.from = e.rect; // from where it is drawn now
        }
        for (auto& e : s.wins) {
            if (!e.inStrip)
                e.from = e.transformer ? std::optional<st::Box>{e.rect} : std::nullopt;
        }
        startAnimation(durationMs);
        post();
    }

    PHLWINDOW frontOfActive(const SSpace& sp) {
        const auto& order = sp.model.stages();
        return order.empty() || order.front().windows.empty() ? nullptr : windowByAddress(order.front().windows.back());
    }

    // The deferred application of model changes: Hyprland's own events (window mapped, closed, moved, focused; workspace
    // switched) and the shell's activate / merge / move requests. Applied from the event loop, outside Hyprland's map,
    // unmap and focus code, one pending call at a time (coalesced): a Lua dispatch with any number of requests causes at
    // most one focus change, so it cannot flood socket2 with Hyprland's own activewindow events (measured: 1000 activate
    // requests applied one by one posted ~1000 activewindowv2 events in one second and Hyprland dropped the shell's
    // socket2 connection, "Socket2 fd 57 overflowed event queue, removing").
    void sync() {
        auto& s = S();
        s.syncLater.reset();
        const auto refocus   = std::exchange(s.refocusSpace, std::nullopt);
        const auto requested = std::exchange(s.focusLater, PHLWINDOWREF{}).lock();
        if (!s.on)
            return;
        PHLWINDOW focus = requested;
        if (!focus && refocus) {
            // A focused window closed: unless Hyprland already gave the keyboard to a window of the active stage, its front
            // window takes it (Hyprland may have picked a strip window, or nothing).
            const auto current = Desktop::focusState() ? Desktop::focusState()->window() : nullptr;
            const auto* sp     = spaceOf(*refocus);
            const bool  fine   = current && sp && sp->model.isActive(addressOf(current));
            const bool  other  = current && !spaceHolding(addressOf(current)) && current->m_workspace && current->m_workspace->m_id != *refocus;
            if (sp && !fine && !other)
                focus = frontOfActive(*sp);
        }
        retarget(s.durationMs, focus);
    }

    // `refocus`: after a close, the active stage of this workspace takes the keyboard unless Hyprland gave it to one of its
    // windows. `focus`: the window a request made key (the latest request wins).
    void scheduleSync(std::optional<st::WorkspaceId> refocus = std::nullopt, const PHLWINDOW& focus = nullptr) {
        auto& s = S();
        if (refocus)
            s.refocusSpace = refocus;
        if (focus)
            s.focusLater = focus;
        if (s.syncLater || !g_pEventLoopManager)
            return;
        s.syncLater = g_pEventLoopManager->doLater([] { gf::guarded("stages sync", [] { sync(); }); });
    }

    // ---- Hyprland events ----

    // The window joins its workspace's stages (a new window, a restored one, one moved in from another workspace).
    void adopt(const PHLWINDOW& w) {
        auto& s = S();
        if (!s.on || !manageable(w))
            return;
        auto& sp = ensureSpace(w->m_workspace->m_id);
        if (!sp.model.add(infoOf(w), s.nextId)) {
            if (!sp.model.contains(addressOf(w)))
                gf::logRequest(Log::INFO, "stages: window {:x} not managed (workspace full: {} windows)", addressOf(w), st::kMaxWindowsPerWorkspace);
            return;
        }
        scheduleSync();
    }

    // The window leaves Stages now (closed, unmapped, moved away, pinned, tiled): shown normally at once. When it held the
    // keyboard, the active stage of its workspace takes it after Hyprland's own refocus (sync).
    void drop(const PHLWINDOW& w) {
        auto&          s       = S();
        const uint64_t address = addressOf(w);
        std::optional<st::WorkspaceId> from;
        for (auto& sp : s.spaces) {
            if (sp.model.remove(address))
                from = sp.id;
        }
        bool changed = from.has_value();
        if (auto* e = winOf(address)) {
            release(*e);
            std::erase_if(s.wins, [address](const SWin& x) { return x.address == address; });
            changed = true;
        }
        if (!changed || !s.on)
            return;
        const bool focused = Desktop::focusState() && Desktop::focusState()->window() == w;
        scheduleSync(focused ? from : std::nullopt);
    }

    // A window's properties changed (floating, pinned, full screen): it joins or leaves Stages accordingly; a strip window
    // made full screen (a dispatch by address) brings its stage forward.
    void reconsider(const PHLWINDOW& w) {
        if (!S().on || !w)
            return;
        const uint64_t address = addressOf(w);
        auto*          sp      = spaceHolding(address);
        if (manageable(w) && !sp)
            adopt(w);
        else if (!manageable(w) && sp)
            drop(w);
        else if (sp && fullscreenNow(w) && !sp->model.isActive(address)) {
            if (const auto stage = sp->model.stageOf(address))
                sp->model.activate(*stage);
            scheduleSync();
        } else
            scheduleSync(); // e.g. full screen on its workspace: its strip goes away while it is shown
    }

    bool closingReason(Desktop::eFocusReason reason) {
        return reason == Desktop::FOCUS_REASON_UNMAP_WINDOW_TILING || reason == Desktop::FOCUS_REASON_UNMAP_WINDOW_FLOATING ||
            reason == Desktop::FOCUS_REASON_UNMAP_GROUPED_WINDOW;
    }

    // Hyprland focused a window. A strip window chosen by the user (a key binding, the Dock, an activation request)
    // brings its stage forward (macOS: activating an app shows its stage). A strip window Hyprland picked after a close is
    // not a choice: the keyboard goes to the active stage instead. A window of the active stage comes to its front.
    void onActive(const PHLWINDOW& w, Desktop::eFocusReason reason) {
        auto& s = S();
        if (!s.on || !w)
            return;
        const uint64_t address = addressOf(w);
        auto*          sp      = spaceHolding(address);
        if (!sp)
            return;
        if (sp->model.isActive(address)) {
            sp->model.raise(address);
            return;
        }
        if (closingReason(reason)) {
            gf::logRequest(Log::DEBUG, "stages: Hyprland focused strip window {:x} after a close: the active stage takes the keyboard", address);
            scheduleSync(sp->id);
            return;
        }
        if (const auto stage = sp->model.stageOf(address); stage && sp->model.activate(*stage)) {
            sp->model.raise(address);
            gf::logRequest(Log::INFO, "stages: strip window {:x} focused (reason {}): its stage {} becomes active", address, static_cast<int>(reason), *stage);
            scheduleSync();
        }
    }

    // A strip surface went away (the shell exited or unmapped it): that monitor's windows are shown normally at once.
    void onLayerClosed(const PHLLS& ls) {
        auto& s = S();
        if (!ls || ls->m_namespace != STRIP_NAMESPACE)
            return;
        const auto mon    = ls->m_monitor.lock();
        const auto before = s.strips.size();
        std::erase_if(s.strips, [&mon](const SStrip& strip) { return !strip.mon.lock() || strip.mon.lock() == mon; });
        if (s.strips.size() == before || !s.on)
            return;
        gf::logRequest(Log::INFO, "stages: the shell's strip surface on {} went away: its windows are shown normally", mon ? mon->m_name : std::string{"?"});
        retarget(0);
        post(st::Reason::Interrupted);
    }

    void onMonitorsChanged() {
        auto& s = S();
        if (!s.on)
            return;
        std::erase_if(s.strips, [](const SStrip& strip) { return !strip.mon.lock() || !monitorByName(strip.monitor); });
        retarget(0); // tiles may lie outside a moved monitor: the shell sends new strips
        post(st::Reason::Interrupted);
    }

    // While windows are drawn in a strip, a frame of this monitor may come from damage at a strip window's real place (its
    // content changed): the thumbnail boxes of this monitor are added to the frame's damage (render.pre, after Hyprland's
    // animation tick, before beginRender reads the damage ring). Frames without damage are not touched. The strip overlap
    // (an active-stage window near the tiles) is checked in the same frame and posted when it changes.
    void onRenderPre(const PHLMONITOR& mon) {
        auto& s = S();
        if (!s.on || !mon || !mon->m_damage.hasChanged())
            return;
        for (auto& e : s.wins) {
            const auto w = e.window.lock();
            if (!w || !e.transformer || w->m_monitor.lock() != mon)
                continue;
            const st::Box box = tf::visualBox(w, e.rect);
            for (const auto& b : gf::overview::damageStep(e.damaged, box))
                mon->m_damage.damage(tf::toCBox(b).translate(-mon->m_position).scale(mon->m_scale).round());
            e.damaged = box;
        }
        SStrip* strip = stripOn(mon);
        if (!strip || !mon->m_activeWorkspace || !Desktop::windowState())
            return;
        const st::Box band    = st::stripBand(strip->tiles, OVERLAP_MARGIN);
        bool          overlap = false;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (!w || !w->m_isMapped || w->isHidden() || w->m_workspace != mon->m_activeWorkspace || !w->acceptsInput())
                continue;
            const st::Box full = tf::fullBox(w);
            if (gf::minimize::intersects(full, band)) {
                overlap = true;
                break;
            }
        }
        if (overlap != strip->overlap) {
            strip->overlap = overlap;
            post();
        }
    }

    // ---- transformer ----

    SP<Render::IFramebuffer> drawStage(const CStageTransformer* self, const SP<Render::IFramebuffer>& in) {
        if (!in || !tf::monitorFrame())
            return in;
        auto&      all = S().wins;
        const auto it  = std::ranges::find_if(all, [self](const SWin& e) { return e.transformer == self; });
        if (it == all.end())
            return in;
        const auto w   = it->window.lock();
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!w || !mon)
            return in;
        if (gf::overviewer::transforms(w))
            return in; // the overview draws this window now (its transformer comes after or before this one: both see `in`)
        if (mon != w->m_monitor.lock())
            return tf::drawNothing(in); // a window spanning monitors is shown only in its own monitor's strip
        return tf::drawFitted(w, it->rect, in, S().warnedNoBuffer, it->address);
    }

    SP<Render::IFramebuffer> CStageTransformer::transform(SP<Render::IFramebuffer> in) {
        SP<Render::IFramebuffer> out = in;
        gf::guarded("stages transform", [&] { out = drawStage(this, in); });
        return out;
    }

    // ---- requests ----

    // Stages ends: every window shown normally again (input unblocked at once, transformers detached after the animation).
    void turnOff(double durationMs, st::Reason reason) {
        auto& s = S();
        if (!s.on && s.wins.empty()) {
            post(reason);
            return;
        }
        s.on = false;
        s.spaces.clear();
        s.strips.clear();
        if (s.syncLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.syncLater);
        s.syncLater.reset();
        s.refocusSpace.reset();
        s.focusLater.reset();
        retarget(durationMs); // nothing is targeted any more: every window animates back to its live box
        post(reason);
    }

    // Stages starts: the windows of every workspace are grouped by app, the focused window's stage active.
    void turnOn() {
        auto& s = S();
        s.on    = true;
        s.spaces.clear();
        if (!Desktop::windowState())
            return;
        const auto                                       focused = Desktop::focusState() ? Desktop::focusState()->window() : nullptr;
        std::vector<std::pair<st::WorkspaceId, std::vector<st::WindowInfo>>> perSpace;
        for (const auto& w : Desktop::windowState()->windows()) { // bottom to top
            if (!manageable(w))
                continue;
            const auto id = w->m_workspace->m_id;
            auto       it = std::ranges::find_if(perSpace, [id](const auto& p) { return p.first == id; });
            if (it == perSpace.end()) {
                perSpace.emplace_back(id, std::vector<st::WindowInfo>{});
                it = perSpace.end() - 1;
            }
            it->second.push_back(infoOf(w));
        }
        for (const auto& [id, windows] : perSpace) {
            auto& sp = ensureSpace(id);
            sp.model.reset(windows, focused ? std::optional<st::WindowId>{addressOf(focused)} : std::nullopt, s.nextId);
        }
    }

    // Each strip's monitor exists, has the shell's strip surface (mapped, Top or Overlay layer) and that surface and its
    // input region cover every tile.
    bool stripsCovered(const std::vector<st::Strip>& strips) {
        for (const auto& strip : strips) {
            const auto mon = monitorByName(strip.monitor);
            if (!mon) {
                gf::logRequest(Log::WARN, "stages: rejected: no monitor {}", strip.monitor);
                return false;
            }
            const auto ls = stripSurfaceOn(mon);
            if (!ls) {
                gf::logRequest(Log::WARN, "stages: rejected: no mapped {} surface on {}", STRIP_NAMESPACE, strip.monitor);
                return false;
            }
            const st::Box box{ls->m_geometry.x, ls->m_geometry.y, ls->m_geometry.w, ls->m_geometry.h};
            const bool    layerOk = ls->m_layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP;
            const bool    inputOk = std::ranges::all_of(strip.tiles, [&ls](const st::Box& t) { return inputCovers(ls, t); });
            if (!layerOk || !st::tilesCovered(strip.tiles, box, monitorBox(mon)) || !inputOk) {
                gf::logRequest(Log::WARN, "stages: rejected: the {} surface on {} (layer {}, box {:.0f},{:.0f} {:.0f}x{:.0f}) must be on the Top or Overlay layer and cover every tile with its input region",
                               STRIP_NAMESPACE, strip.monitor, ls->m_layer, box.x, box.y, box.w, box.h);
                return false;
            }
        }
        return true;
    }

} // namespace

namespace gf::stager {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !Fullscreen::controller() || !Desktop::windowState() || !State::monitorState())
            return false;
        // A load starts with the flag off and nothing managed, also when the library stayed mapped since a previous load
        // (FR23 pins it while appmenu clients are alive, so this function-static state can outlive an unload).
        auto& s   = S();
        s.enabled = false;
        s.on      = false;
        s.spaces.clear();
        s.wins.clear();
        s.strips.clear();
        auto& ev = bus->m_events;
        auto& l  = S().listeners;
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("stages tick", [] { tick(); }); }));
        l.push_back(ev.render.pre.listen([](const PHLMONITOR& monitor) { gf::guarded("stages render.pre", [&] { onRenderPre(monitor); }); }));
        l.push_back(ev.window.open.listen([](const PHLWINDOW& w) { gf::guarded("stages window.open", [&] { adopt(w); }); }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("stages window.close", [&] { drop(w); }); }));
        l.push_back(ev.window.destroy.listen([](const PHLWINDOWREF& /*w*/) {
            gf::guarded("stages window.destroy", [] { std::erase_if(S().wins, [](const SWin& e) { return !e.window.lock(); }); });
        }));
        l.push_back(ev.window.moveToWorkspace.listen([](const PHLWINDOW& w, const PHLWORKSPACE& /*ws*/) {
            gf::guarded("stages window.moveToWorkspace", [&] {
                drop(w);  // out of its old workspace's stages, shown normally
                adopt(w); // into the new workspace's stages (a regular workspace only: minimized windows stay out)
            });
        }));
        l.push_back(ev.window.floating.listen([](const PHLWINDOW& w) { gf::guarded("stages window.floating", [&] { reconsider(w); }); }));
        l.push_back(ev.window.pin.listen([](const PHLWINDOW& w) { gf::guarded("stages window.pin", [&] { reconsider(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("stages window.fullscreen", [&] { reconsider(w); }); }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason reason) { gf::guarded("stages window.active", [&] { onActive(w, reason); }); }));
        l.push_back(ev.workspace.active.listen([](const PHLWORKSPACE& /*ws*/) {
            gf::guarded("stages workspace.active", [] {
                if (S().on)
                    scheduleSync();
            });
        }));
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) { gf::guarded("stages layer.closed", [&] { onLayerClosed(ls); }); }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("stages monitor.removed", [] { onMonitorsChanged(); }); }));
        l.push_back(ev.monitor.layoutChanged.listen([] { gf::guarded("stages monitor.layoutChanged", [] { onMonitorsChanged(); }); }));
        S().ready = true;
        return true;
    }

    void stop() {
        auto& s = S();
        s.ready = false;
        s.listeners.clear();
        if (s.syncLater && g_pEventLoopManager)
            g_pEventLoopManager->removeDoLater(*s.syncLater); // its callback is code of this library
        s.syncLater.reset();
        s.refocusSpace.reset();
        s.focusLater.reset();
        const bool wasOn = s.on || !s.wins.empty();
        s.on             = false;
        s.enabled        = false;
        s.animating      = false;
        for (auto& e : s.wins)
            release(e); // no transformer of this library may outlive dlclose; no window may stay blocked
        s.wins.clear();
        s.spaces.clear();
        s.strips.clear();
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
        if (wasOn)
            post(st::Reason::Unavailable);
    }

    bool ready() {
        return S().ready;
    }

    bool enabled() {
        return S().enabled;
    }

    void setEnabled(bool on) {
        auto& s = S();
        if (s.enabled == on)
            return;
        s.enabled = on;
        if (!on && (s.on || !s.wins.empty()))
            turnOff(0, st::Reason::Disabled);
    }

    void refuse(st::Reason reason) {
        post(reason);
    }

    void request(const st::Request& r) {
        auto& s = S();
        if (!s.ready) {
            post(st::Reason::Unavailable);
            return;
        }
        if (r.op == st::Op::Off) {
            turnOff(r.durationMs, st::Reason::None);
            return;
        }
        if (!s.enabled) {
            gf::logRequest(Log::WARN, "stages: rejected: the feature flag is off (config {} = true first)", st::kConfigStagesEnabled);
            refuse(st::Reason::Disabled);
            return;
        }
        switch (r.op) {
            case st::Op::On: {
                if (!stripsCovered(r.strips)) {
                    refuse(st::Reason::NoStrip);
                    return;
                }
                std::vector<SStrip> strips;
                for (const auto& strip : r.strips) {
                    const auto mon     = monitorByName(strip.monitor);
                    const auto* before = stripOn(mon);
                    strips.push_back(SStrip{.monitor = strip.monitor, .mon = mon, .tiles = strip.tiles, .hidden = strip.hidden, .overlap = before && before->overlap});
                }
                s.strips     = std::move(strips);
                s.durationMs = r.durationMs;
                s.curve      = r.curve;
                const bool starting = !s.on;
                if (starting)
                    turnOn();
                gf::logRequest(Log::INFO, "stages: {} with {} strip(s), {:.0f} ms", starting ? "on" : "strips updated", s.strips.size(), r.durationMs);
                retarget(r.durationMs);
                return;
            }
            case st::Op::Activate:
            case st::Op::Merge: {
                auto* sp = s.on ? spaceWithStage(r.stage) : nullptr;
                const bool ok = sp && (r.op == st::Op::Activate ? sp->model.activate(r.stage) : sp->model.merge(r.stage));
                if (!ok) {
                    gf::logRequest(Log::INFO, "stages: {} {}: no such strip stage", r.op == st::Op::Activate ? "activate" : "merge", r.stage);
                    refuse(st::Reason::Unknown);
                    return;
                }
                scheduleSync(std::nullopt, frontOfActive(*sp)); // applied once per event loop pass (coalesced)
                return;
            }
            case st::Op::Move: {
                auto* sp = s.on ? spaceHolding(r.window) : nullptr;
                if (!sp || (!r.newStage && !std::ranges::any_of(sp->model.stages(), [&r](const st::Stage& x) { return x.id == r.stage; }))) {
                    gf::logRequest(Log::INFO, "stages: move {:x}: unknown window or stage (stages are per workspace)", r.window);
                    refuse(st::Reason::Unknown);
                    return;
                }
                const bool wasActive = sp->model.isActive(r.window);
                if (!sp->model.moveWindow(r.window, r.newStage ? std::nullopt : std::optional<st::StageId>{r.stage}, s.nextId)) {
                    refuse(st::Reason::Unknown);
                    return;
                }
                const bool nowActive = sp->model.isActive(r.window);
                // Onto the stage: that window becomes key. Out of the stage: the stage's front window keeps or takes the keyboard.
                scheduleSync(std::nullopt, nowActive ? windowByAddress(r.window) : (wasActive ? frontOfActive(*sp) : nullptr));
                return;
            }
            case st::Op::Off: break;
        }
    }

} // namespace gf::stager
