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
        struct SMonitor {
            PHLMONITORREF                  monitor;
            CHyprSignalListener            presented;
            std::unique_ptr<frames::CRing> ring = std::make_unique<frames::CRing>();
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners; // monitors added / removed
            std::vector<SMonitor>            monitors;
            bool                             ready = false;
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
        s.ready = false;
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
            out.push_back(frames::MonitorFrames{.name = m->m_name, .refreshHz = m->m_refreshRate, .total = e.ring->total(), .presentedUs = e.ring->snapshot()});
        }
        return frames::framesJson(out);
    }

} // namespace gf::frameProbe
