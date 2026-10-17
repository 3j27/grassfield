#include "Overview.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
#include "core/EventThrottle.hpp"
#include "core/Minimize.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

namespace ov = gf::overview;

namespace {
    // Layer namespace of the shell's overview surface (shell/overview/OverviewWindow.qml). When it goes away (the shell
    // exited or crashed) an open overview closes, so windows never stay transformed without a shell to end it.
    constexpr std::string_view OVERVIEW_LAYER_NAMESPACE = "grassfield-overview";

    // Ends animations whose frames stopped (no monitor rendered): checked this long after the expected end.
    constexpr auto WATCHDOG_SLACK = std::chrono::milliseconds(150);

    // Attached to a transformed window (CWindow::m_transformers, owned by the window). Hyprland calls transform() with
    // a monitor-sized work buffer holding the window's main pass at its real place; it returns the buffer to composite.
    class COverviewTransformer final : public Render::IWindowTransformer {
      public:
        SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override;
    };

    struct SEntry {
        PHLWINDOWREF          window;
        uint64_t              address = 0;
        PHLMONITORREF         monitor;               // the window's monitor when it entered the overview
        COverviewTransformer* transformer = nullptr; // owned by window->m_transformers; compared, never freed here
        std::optional<ov::Box> from;                 // nullopt: the window's live surface box
        std::optional<ov::Box> to;                   // nullopt: the window's live surface box
        ov::Box               rect;                  // layout rect the surface box is fitted into, at the last tick
        ov::Box               damaged;               // last damaged visual box (layout, with every decoration)
        bool                  kept = false;          // retarget bookkeeping
    };

    struct SOverviewState {
        bool                             ready = false;
        ov::Phase                        phase = ov::Phase::Closed;
        ov::Reason                       closeReason = ov::Reason::None;
        std::vector<SEntry>              entries;
        Time::steady_tp                  start;
        double                           durationMs = 0;
        ov::Curve                        curve;
        std::vector<CHyprSignalListener> listeners;
        SP<CEventLoopTimer>              watchdog; // shared: CEventLoopManager holds a strong reference too
        bool                             warnedNoBuffer = false;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SOverviewState& st() {
        static SOverviewState s;
        return s;
    }

    ov::Box toBox(const CBox& b) {
        return ov::Box{b.x, b.y, b.w, b.h};
    }

    CBox toCBox(const ov::Box& b) {
        return CBox{b.x, b.y, b.w, b.h};
    }

    bool hasArea(const ov::Box& b) {
        return b.w > 0 && b.h > 0;
    }

    void post(ov::Phase phase, size_t windows, ov::Reason reason = ov::Reason::None) {
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Overview, .id = 0}, ov::eventJson(phase, windows, reason));
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

    // Windows of the current workspace of their monitor, drawn by Hyprland's normal window pass: mapped, visible, not
    // pinned (pinned windows are drawn on every workspace), not on a special workspace (minimized windows live on
    // special:minimized), not full screen (maximized windows are fine).
    bool eligible(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || w->isHidden() || w->m_pinned)
            return false;
        const auto ws  = w->m_workspace;
        const auto mon = w->m_monitor.lock();
        if (!ws || ws->m_isSpecialWorkspace || !mon || mon->m_activeWorkspace != ws)
            return false;
        const auto& fullscreen = Fullscreen::controller();
        return fullscreen && fullscreen->getFullscreenModes(w).internal != Fullscreen::FSMODE_FULLSCREEN;
    }

    ov::Box monitorBox(const PHLMONITOR& mon) {
        return ov::Box{mon->m_position.x, mon->m_position.y, mon->m_size.x, mon->m_size.y};
    }

    ov::Box surfaceBox(const PHLWINDOW& w) {
        return toBox(w->getWindowMainSurfaceBox());
    }

    // What Hyprland adds to a window's position when it renders it (workspace slide, floating offset).
    Vector2D renderOffset(const PHLWINDOW& w) {
        Vector2D off = w->m_floatingOffset;
        if (!w->m_pinned && w->m_workspace && w->m_workspace->m_renderOffset)
            off = off + w->m_workspace->m_renderOffset->value();
        return off;
    }

    ov::Box translated(const ov::Box& b, const Vector2D& by) {
        return ov::Box{b.x + by.x, b.y + by.y, b.w, b.h};
    }

    // The window's surface box with every decoration extent (titlebar, border, shadow), as drawn at its place.
    ov::Box fullBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::FULL_EXTENTS | Desktop::View::RESERVED_EXTENTS));
        return toBox(box.expand(2.0));
    }

    // Where the window and its decorations are drawn now (layout).
    ov::Box visualBox(const SEntry& e, const PHLWINDOW& w) {
        const ov::Box surface = surfaceBox(w);
        return translated(gf::minimize::mapBox(fullBox(w), surface, ov::drawBox(surface, e.rect)), renderOffset(w));
    }

    // Damages the previous and the current visual box (and so schedules frames on the monitors they touch).
    void damage(SEntry& e, const PHLWINDOW& w) {
        if (!g_pHyprRenderer)
            return;
        const ov::Box box = visualBox(e, w);
        if (hasArea(e.damaged) && !(e.damaged == box))
            g_pHyprRenderer->damageBox(toCBox(e.damaged));
        g_pHyprRenderer->damageBox(toCBox(box));
        e.damaged = box;
    }

    COverviewTransformer* attach(const PHLWINDOW& w) {
        auto  transformer = makeUnique<COverviewTransformer>();
        auto* raw         = transformer.get();
        w->m_transformers.emplace_back(std::move(transformer));
        if (g_pHyprRenderer)
            g_pHyprRenderer->damageWindow(w);
        return raw;
    }

    // Back to normal rendering: the transformer leaves the window (a destroyed window took it along).
    void detach(SEntry& e) {
        if (g_pHyprRenderer && hasArea(e.damaged))
            g_pHyprRenderer->damageBox(toCBox(e.damaged));
        const auto w = e.window.lock();
        if (w && e.transformer) {
            std::erase_if(w->m_transformers, [&e](const UP<Render::IWindowTransformer>& t) { return t.get() == e.transformer; });
            if (g_pHyprRenderer)
                g_pHyprRenderer->damageWindow(w);
        }
        e.transformer = nullptr;
        e.damaged     = {};
    }

    void detachAll() {
        auto entries = std::exchange(st().entries, {});
        for (auto& e : entries)
            detach(e);
    }

    void finishClosed(ov::Reason reason) {
        detachAll();
        st().phase = ov::Phase::Closed;
        post(ov::Phase::Closed, 0, reason);
    }

    void tick();

    void armWatchdog() {
        auto& s = st();
        if (!g_pEventLoopManager)
            return;
        if (!s.watchdog) {
            s.watchdog = makeShared<CEventLoopTimer>(
                std::nullopt,
                [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) {
                    gf::guarded("overview watchdog", [] {
                        tick();
                        const auto& s = st();
                        if ((s.phase == ov::Phase::Opening || s.phase == ov::Phase::Closing) && s.watchdog)
                            s.watchdog->updateTimeout(WATCHDOG_SLACK);
                    });
                },
                nullptr);
            g_pEventLoopManager->addTimer(s.watchdog);
        }
        s.watchdog->updateTimeout(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::duration<double, std::milli>(s.durationMs)) + WATCHDOG_SLACK);
    }

    // One animation step; called before each monitor frame (render.preChecks, where Hyprland ticks its own animations)
    // and by the watchdog. Damage schedules the next frames while the animation runs.
    void tick() {
        auto& s = st();
        if (s.phase != ov::Phase::Opening && s.phase != ov::Phase::Closing)
            return;
        const double elapsedMs = std::chrono::duration<double, std::milli>(Time::steadyNow() - s.start).count();
        const double t         = ov::progress(elapsedMs, s.durationMs);
        const double e         = ov::eased(s.curve, t);
        for (auto it = s.entries.begin(); it != s.entries.end();) {
            const auto w = it->window.lock();
            if (!w) {
                detach(*it);
                it = s.entries.erase(it);
                continue;
            }
            it->rect = ov::interpolate(it->from, it->to, surfaceBox(w), e);
            damage(*it, w);
            ++it;
        }
        if (t < 1.0)
            return;
        if (s.phase == ov::Phase::Opening) {
            s.phase = ov::Phase::Open;
            post(ov::Phase::Open, s.entries.size());
        } else
            finishClosed(s.closeReason);
    }

    // While the overview is shown, a frame of this monitor may come from any damage at a window's real place (its
    // content changed) that Hyprland does not know is drawn elsewhere: the layout boxes of this monitor are added to
    // the frame's damage before it is computed (render.pre comes after Hyprland's animation tick and before
    // beginRender reads the damage ring). Frames without damage are not touched, so an idle overview costs nothing.
    void onRenderPre(const PHLMONITOR& mon) {
        auto& s = st();
        if (s.phase == ov::Phase::Closed || !mon || !mon->m_damage.hasChanged())
            return;
        for (auto& e : s.entries) {
            if (e.monitor.lock() != mon)
                continue;
            const auto w = e.window.lock();
            if (!w)
                continue;
            for (const auto& box : {e.damaged, visualBox(e, w)}) {
                if (hasArea(box))
                    mon->m_damage.damage(toCBox(box).translate(-mon->m_position).scale(mon->m_scale).round());
            }
        }
    }

    void startAnimation(ov::Phase phase, double durationMs, const ov::Curve& curve) {
        auto& s      = st();
        s.phase      = phase;
        s.start      = Time::steadyNow();
        s.durationMs = durationMs;
        s.curve      = curve;
        for (auto& e : s.entries) {
            if (const auto w = e.window.lock()) {
                e.rect = ov::interpolate(e.from, e.to, surfaceBox(w), 0.0);
                damage(e, w);
            }
        }
        post(phase, s.entries.size(), phase == ov::Phase::Closing ? s.closeReason : ov::Reason::None);
        if (durationMs <= 0)
            tick(); // no animation (Reduce Motion): the end state now
        else
            armWatchdog();
    }

    void startClosing(double durationMs, const ov::Curve& curve, ov::Reason reason) {
        auto& s = st();
        if (s.phase == ov::Phase::Closed) {
            post(ov::Phase::Closed, 0, reason);
            return;
        }
        for (auto& e : s.entries) {
            e.from = e.rect; // from where it is now, back to its live place
            e.to.reset();
        }
        s.closeReason = reason;
        startAnimation(ov::Phase::Closing, durationMs, curve);
    }

    // A window that closes, unmaps or leaves its workspace goes back to normal rendering at once.
    void dropWindow(const PHLWINDOW& w) {
        auto& all = st().entries;
        for (auto it = all.begin(); it != all.end();) {
            const auto ew = it->window.lock();
            if (!ew || ew == w) {
                detach(*it);
                it = all.erase(it);
            } else
                ++it;
        }
    }

    bool animatingOrOpen() {
        const auto phase = st().phase;
        return phase == ov::Phase::Opening || phase == ov::Phase::Open;
    }

    // Hyprland leaves the render damage at the window's own box once it has rendered the window into the work buffer
    // (CRenderPass::render stores its damage). Clears and draws here must cover the whole buffer: a work buffer keeps
    // the content of its previous use, and the composite samples all of it. The damage is restored afterwards.
    class CWholeBufferDamage {
      public:
        explicit CWholeBufferDamage(const PHLMONITOR& mon) : m_saved(g_pHyprRenderer->m_renderData.damage.copy()) {
            g_pHyprRenderer->m_renderData.damage = CRegion{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y};
        }
        ~CWholeBufferDamage() {
            g_pHyprRenderer->m_renderData.damage = m_saved;
        }
        CWholeBufferDamage(const CWholeBufferDamage&)            = delete;
        CWholeBufferDamage& operator=(const CWholeBufferDamage&) = delete;
        CWholeBufferDamage(CWholeBufferDamage&&)                 = delete;
        CWholeBufferDamage& operator=(CWholeBufferDamage&&)      = delete;

      private:
        CRegion m_saved;
    };

    SP<Render::IFramebuffer> drawTransformed(const COverviewTransformer* self, const SP<Render::IFramebuffer>& in) {
        // Only the monitor frame: snapshots (close and minimize animations) and window captures (toplevel export,
        // RPT_EXPORT) show the window as it is.
        if (!in || !g_pHyprRenderer || g_pHyprRenderer->m_bRenderingSnapshot || g_pHyprRenderer->m_renderData.projectionType != Render::RPT_MONITOR)
            return in;
        const auto& all = st().entries;
        const auto  it  = std::ranges::find_if(all, [self](const SEntry& e) { return e.transformer == self; });
        if (it == all.end())
            return in;
        const auto w   = it->window.lock();
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!w || !mon)
            return in;
        if (mon != it->monitor.lock()) {
            // A window that spans monitors is shown only in the overview of its own monitor: here it is drawn as
            // nothing (the work buffer `in` is the bound framebuffer).
            const CWholeBufferDamage whole{mon};
            g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
            return in;
        }
        const auto tex = in->getTexture();
        if (!tex)
            return in;
        // resources() is a weak reference to a unique pointer: it must not be lock()ed (hyprutils aborts), only
        // checked and dereferenced, as Hyprland's own drawTransformedWindow does.
        const auto resources = mon->resources();
        auto       out       = resources && !resources.expired() ? resources->getUnusedWorkBuffer() : nullptr;
        if (!out) {
            if (!st().warnedNoBuffer)
                gf::log(Log::WARN, "overview: no free work buffer; window {:x} drawn at its place this frame", it->address);
            st().warnedNoBuffer = true;
            return in;
        }

        // The whole buffer is drawn scaled and moved so that the window's surface box lands on its layout box (same
        // math as the minimize snapshot, on the same monitor). Decorations and shadow scale with it.
        const ov::Box surface = surfaceBox(w);
        const auto    off     = renderOffset(w);
        const ov::Box src     = translated(surface, off);
        const ov::Box dst     = translated(ov::drawBox(surface, it->rect), off);
        const gf::minimize::SSnapshotGeometry geometry{.visible      = src,
                                                       .monitorX     = mon->m_position.x,
                                                       .monitorY     = mon->m_position.y,
                                                       .monitorScale = mon->m_scale,
                                                       .texW         = mon->m_transformedSize.x,
                                                       .texH         = mon->m_transformedSize.y};
        const ov::Box texBox = gf::minimize::textureBox(geometry, dst, mon->m_position.x, mon->m_position.y, mon->m_scale);

        const CWholeBufferDamage whole{mon};
        const auto               guard = g_pHyprRenderer->bindTempFB(out);
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        CTexPassElement::SRenderData data;
        data.tex = tex;
        data.box = toCBox(texBox);
        data.a   = 1.F;
        g_pHyprRenderer->draw(data, CRegion{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y});
        return out;
    }

    SP<Render::IFramebuffer> COverviewTransformer::transform(SP<Render::IFramebuffer> in) {
        SP<Render::IFramebuffer> out = in;
        gf::guarded("overview transform", [&] { out = drawTransformed(this, in); });
        return out;
    }
} // namespace

namespace gf::overviewer {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !Fullscreen::controller())
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        l.push_back(ev.render.preChecks.listen([](const PHLMONITOR& /*monitor*/) { gf::guarded("overview tick", [] { tick(); }); }));
        l.push_back(ev.render.pre.listen([](const PHLMONITOR& monitor) { gf::guarded("overview damage", [&] { onRenderPre(monitor); }); }));
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("overview window.close", [&] { dropWindow(w); }); }));
        l.push_back(ev.window.destroy.listen([](const PHLWINDOWREF& /*w*/) { gf::guarded("overview window.destroy", [] { dropWindow(nullptr); }); }));
        l.push_back(ev.window.moveToWorkspace.listen([](const PHLWINDOW& w, const PHLWORKSPACE& /*ws*/) { gf::guarded("overview window.moveToWorkspace", [&] { dropWindow(w); }); }));
        // A window that becomes full screen or pinned is drawn by other render paths: back to normal at once.
        const auto dropIfIneligible = [](const PHLWINDOW& w) {
            gf::guarded("overview window state", [&] {
                if (w && !eligible(w))
                    dropWindow(w);
            });
        };
        l.push_back(ev.window.fullscreen.listen(dropIfIneligible));
        l.push_back(ev.window.pin.listen(dropIfIneligible));
        // Failsafes: a window that gets the keyboard ends the overview (macOS: the clicked window becomes key and the
        // overview zooms back), and so does the end of the shell's overview surface; a workspace switch or a monitor
        // change puts every window back at once.
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason /*reason*/) {
            gf::guarded("overview window.active", [&] {
                if (w && animatingOrOpen())
                    startClosing(st().durationMs, st().curve, ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) {
            gf::guarded("overview layer.closed", [&] {
                if (ls && ls->m_namespace == OVERVIEW_LAYER_NAMESPACE && animatingOrOpen())
                    startClosing(st().durationMs, st().curve, ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.workspace.active.listen([](const PHLWORKSPACE& /*ws*/) {
            gf::guarded("overview workspace.active", [] {
                const auto& s = st();
                if (s.phase == ov::Phase::Closed)
                    return;
                const bool moved = std::ranges::any_of(s.entries, [](const SEntry& e) {
                    const auto w   = e.window.lock();
                    const auto mon = e.monitor.lock();
                    return !w || !mon || mon->m_activeWorkspace != w->m_workspace;
                });
                if (moved)
                    finishClosed(ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& /*monitor*/) {
            gf::guarded("overview monitor.removed", [] {
                if (st().phase != ov::Phase::Closed)
                    finishClosed(ov::Reason::Interrupted);
            });
        }));
        l.push_back(ev.monitor.layoutChanged.listen([] {
            gf::guarded("overview monitor.layoutChanged", [] {
                if (st().phase != ov::Phase::Closed)
                    finishClosed(ov::Reason::Interrupted);
            });
        }));
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.listeners.clear();
        if (s.phase != ov::Phase::Closed)
            finishClosed(ov::Reason::Unavailable); // no transformer of this library may outlive dlclose
        if (s.watchdog) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.watchdog);
            s.watchdog.reset();
        }
    }

    bool ready() {
        return st().ready;
    }

    void refuse(ov::Reason reason) {
        const auto& s = st();
        post(s.phase, s.entries.size(), reason);
    }

    void request(const ov::Request& r) {
        auto& s = st();
        if (!s.ready) {
            post(ov::Phase::Closed, 0, ov::Reason::Unavailable);
            return;
        }
        if (!r.on) {
            startClosing(r.durationMs, r.curve, ov::Reason::None);
            return;
        }

        std::vector<SEntry> next;
        for (auto& old : s.entries)
            old.kept = false;
        for (const auto& target : r.windows) {
            const auto w = windowByAddress(target.address);
            if (!eligible(w)) {
                gf::logRequest(Log::INFO, "overview: window {:x} skipped (unknown, unmapped, hidden, pinned, full screen or not on its monitor's workspace)",
                               target.address);
                continue;
            }
            const auto mon = w->m_monitor.lock();
            if (!ov::insideMonitor(target.rect, monitorBox(mon))) {
                gf::logRequest(Log::INFO, "overview: window {:x} skipped: rect {:.0f},{:.0f} {:.0f}x{:.0f} not inside its monitor {}", target.address, target.rect.x,
                               target.rect.y, target.rect.w, target.rect.h, mon->m_name);
                continue;
            }
            SEntry e{.window = w, .address = target.address, .monitor = mon, .transformer = nullptr, .from = std::nullopt, .to = target.rect, .rect = {}, .damaged = {}};
            // A window already in the overview continues from where it is drawn now.
            const auto old = std::ranges::find_if(s.entries, [&w](const SEntry& o) { return !o.kept && o.window.lock() == w; });
            if (old != s.entries.end()) {
                e.from        = old->rect;
                e.transformer = old->transformer;
                e.damaged     = old->damaged;
                old->kept     = true;
            }
            next.push_back(e);
        }
        if (!r.windows.empty() && next.empty()) {
            gf::logRequest(Log::WARN, "overview: rejected: none of the {} listed window(s) can be transformed", r.windows.size());
            refuse(ov::Reason::NoWindows);
            return;
        }
        for (auto& old : s.entries) {
            if (!old.kept)
                detach(old); // left the layout: back to its place at once
        }
        for (auto& e : next) {
            if (!e.transformer)
                e.transformer = attach(e.window.lock());
        }
        s.entries     = std::move(next);
        s.closeReason = ov::Reason::None;
        gf::logRequest(Log::INFO, "overview: {} window(s), {:.0f} ms", s.entries.size(), r.durationMs);
        startAnimation(ov::Phase::Opening, r.durationMs, r.curve);
    }

} // namespace gf::overviewer
