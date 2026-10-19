#include "CursorRefresh.hpp"

#include "Plugin.hpp"
#include "core/CursorRefresh.hpp"
#include "core/EventThrottle.hpp"

#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/pointer/cursor/CursorManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <chrono>
#include <optional>
#include <string>

namespace gf::cursorRefresh {

    namespace {
        struct SState {
            cursor::CRefreshGate           gate;
            SP<CEventLoopTimer>            timer; // shared with CEventLoopManager; stop() removes it before dlclose
            bool                           running = false;
            std::optional<cursor::Outcome> lastOutcome; // what the last log line said
            std::string                    lastName;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        bool anyOutput() {
            const auto& monitors = State::monitorState();
            return monitors && !monitors->monitors().empty();
        }

        // One line when the outcome or the shape changes, and at 1, 10, 100, ... runs (a slider drag does not flood
        // the log); through the request log budget, since any local client can call the verb.
        void note(cursor::Outcome outcome, const std::string& name) {
            auto&      s       = st();
            const auto shown   = cursor::loggableName(name);
            const bool changed = s.lastOutcome != outcome || s.lastName != shown;
            if (!changed && !events::isLogMilestone(s.gate.runs()))
                return;
            s.lastOutcome = outcome;
            s.lastName    = shown;
            logRequest(Log::INFO, "cursor_refresh: {} '{}' ({} run(s), {} request(s) folded)", cursor::outcomeName(outcome), shown, s.gate.runs(), s.gate.folded());
        }

        void refreshNow() {
            if (!g_pHyprRenderer || !Pointer::Cursor::mgr() || !Pointer::mgr()) {
                logRequest(Log::WARN, "cursor_refresh: renderer or cursor manager unavailable");
                return;
            }
            auto& renderer = *g_pHyprRenderer;
            // A copy: setCursorFromName assigns its argument to m_lastCursorData.name.
            const std::string          name = renderer.m_lastCursorData.name;
            const cursor::SCursorState state{
                .shown       = renderer.shouldRenderCursor(),
                .fromSurface = renderer.m_lastCursorData.surf.has_value(),
                .outputs     = anyOutput(),
                .name        = name,
            };
            const auto outcome = cursor::decide(state);
            if (outcome == cursor::Outcome::Redraw)
                renderer.setCursorFromName(name, true);
            note(outcome, name);
        }

        void onTimer() {
            guarded("cursor refresh timer", [] {
                auto& s = st();
                if (s.running && s.gate.fire(events::Clock::now()))
                    refreshNow();
            });
        }

        void arm(events::Duration delay) {
            auto& s = st();
            if (!g_pEventLoopManager) { // no event loop (should not happen): run the folded refresh now
                if (s.gate.fire(events::Clock::now()))
                    refreshNow();
                return;
            }
            if (!s.timer) {
                s.timer = makeShared<CEventLoopTimer>(std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { onTimer(); }, nullptr);
                g_pEventLoopManager->addTimer(s.timer);
            }
            s.timer->updateTimeout(std::max<events::Duration>(delay, std::chrono::milliseconds(1)));
        }
    } // namespace

    bool start() {
        auto& s = st();
        s.gate.reset(); // the library may have stayed mapped since a previous load
        s.lastOutcome.reset();
        s.lastName.clear();
        s.running = g_pHyprRenderer != nullptr;
        return s.running;
    }

    void stop() {
        auto& s   = st();
        s.running = false;
        if (s.timer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.timer);
            s.timer.reset();
        }
        s.gate.reset();
    }

    bool ready() {
        return st().running;
    }

    void request() {
        auto& s = st();
        if (!s.running)
            return;
        const auto decision = s.gate.request(events::Clock::now());
        switch (decision.action) {
            case cursor::GateAction::Now: refreshNow(); break;
            case cursor::GateAction::Arm: arm(decision.delay); break;
            case cursor::GateAction::Fold:
                if (events::isLogMilestone(s.gate.folded())) // 1, 10, 100, ...: a flood shows in the log without flooding it
                    logRequest(Log::INFO, "cursor_refresh: {} request(s) folded into a trailing refresh (at most one per {} ms)", s.gate.folded(),
                               std::chrono::duration_cast<std::chrono::milliseconds>(cursor::CRefreshGate::kDefaultInterval).count());
                break;
        }
    }

} // namespace gf::cursorRefresh
