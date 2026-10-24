#include "FrameProbe.hpp"

#include "Plugin.hpp"
#include "core/FrameLog.hpp"

#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <chrono>
#include <memory>
#include <vector>

namespace gf::frameProbe {

    namespace {
        // The ring before the listener that writes into it: members are destroyed in reverse order, so the listener goes
        // first.
        struct SMonitor {
            PHLMONITORREF                      monitor;
            std::unique_ptr<frames::CRing>     ring    = std::make_unique<frames::CRing>();
            std::unique_ptr<frames::CSpanRing> renders = std::make_unique<frames::CSpanRing>();
            CHyprSignalListener                presented;
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners; // monitors added / removed, render begin and end
            std::vector<SMonitor>            monitors;
            frames::CMarkRing                marks;
            PHLMONITORREF                    rendering;    // the monitor of the latest render.preChecks
            uint64_t                         renderBegin = 0;
            bool                             inRender    = false;
            bool                             ready       = false;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        uint64_t microseconds(const Time::steady_tp& tp) {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(tp.time_since_epoch()).count());
        }

        void attach(const PHLMONITOR& m) {
            auto& s = st();
            std::erase_if(s.monitors, [](const SMonitor& e) { return e.monitor.expired(); });
            if (!m || std::ranges::any_of(s.monitors, [&m](const SMonitor& e) { return e.monitor.lock() == m; }))
                return;
            SMonitor       e;
            PHLMONITORREF  ref  = m;
            frames::CRing* ring = e.ring.get(); // owned by the entry; the listener dies with it
            e.monitor           = ref;
            e.presented         = m->m_events.presented.listen([ring](const Time::steady_tp& when) {
                guarded("frame probe presented", [&] { ring->push(microseconds(when)); });
            });
            s.monitors.push_back(std::move(e));
        }

        void detach(const PHLMONITOR& m) {
            std::erase_if(st().monitors, [&m](const SMonitor& e) {
                const auto mine = e.monitor.lock();
                return !mine || mine == m;
            });
        }

        // render.preChecks: a frame of `m` may be rendered now (Hyprland skips it when nothing is damaged; then no
        // RENDER_POST follows and the next preChecks starts over).
        void renderBegins(const PHLMONITOR& m) {
            auto& s       = st();
            s.rendering   = m;
            s.renderBegin = microseconds(Time::steadyNow());
            s.inRender    = m != nullptr;
        }

        // RENDER_POST: the frame begun at the latest preChecks is rendered and submitted.
        void renderEnds() {
            auto& s = st();
            if (!s.inRender)
                return;
            s.inRender     = false;
            const auto mon = s.rendering.lock();
            if (!mon)
                return;
            const uint64_t now = microseconds(Time::steadyNow());
            for (auto& e : s.monitors) {
                if (e.renders && e.monitor.lock() == mon) {
                    e.renders->push(frames::RenderSpan{.beginUs = s.renderBegin, .cpuUs = now >= s.renderBegin ? now - s.renderBegin : 0});
                    return;
                }
            }
        }
    } // namespace

    bool start() {
        auto& s = st();
        if (s.ready)
            return true;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events.monitor;
        s.listeners.push_back(ev.added.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.added", [&] { attach(m); }); }));
        s.listeners.push_back(ev.removed.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.removed", [&] { detach(m); }); }));
        s.listeners.push_back(ev.destroyMon.listen([](const PHLMONITOR& m) { guarded("frame probe monitor.destroy", [&] { detach(m); }); }));
        auto& render = bus->m_events.render;
        s.listeners.push_back(render.preChecks.listen([](const PHLMONITOR& m) { guarded("frame probe render begin", [&] { renderBegins(m); }); }));
        s.listeners.push_back(render.stage.listen([](eRenderStage stage) {
            if (stage == RENDER_POST)
                guarded("frame probe render end", [] { renderEnds(); });
        }));
        if (State::monitorState()) {
            for (const auto& m : State::monitorState()->monitors())
                attach(m);
        }
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.monitors.clear(); // the presented listeners first: they point into the rings
        s.listeners.clear();
        s.marks     = {};
        s.rendering = {};
        s.inRender  = false;
        s.ready     = false;
    }

    bool ready() {
        return st().ready;
    }

    std::string json() {
        std::vector<frames::MonitorFrames> out;
        for (const auto& e : st().monitors) {
            const auto m = e.monitor.lock();
            if (!m || !e.ring)
                continue;
            out.push_back(frames::MonitorFrames{.name        = m->m_name,
                                                .refreshHz   = m->m_refreshRate,
                                                .total       = e.ring->total(),
                                                .presentedUs = e.ring->snapshot(),
                                                .renders     = e.renders ? e.renders->snapshot() : std::vector<frames::RenderSpan>{}});
        }
        const auto marks = st().marks.snapshot();
        return frames::framesJson(out, marks);
    }

    void mark(std::string_view what) {
        auto& s = st();
        if (s.ready)
            s.marks.push(microseconds(Time::steadyNow()), what);
    }

} // namespace gf::frameProbe
