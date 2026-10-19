#include "CursorRefresh.hpp"

#include <algorithm>

namespace gf::cursor {

    Outcome decide(const SCursorState& state) {
        if (!state.shown)
            return Outcome::Hidden;
        if (state.fromSurface)
            return Outcome::ClientSurface;
        if (state.name.empty())
            return Outcome::NoShape;
        if (!state.outputs)
            return Outcome::NoOutput;
        return Outcome::Redraw;
    }

    std::string_view outcomeName(Outcome outcome) {
        switch (outcome) {
            case Outcome::Redraw: return "redraw";
            case Outcome::Hidden: return "hidden";
            case Outcome::ClientSurface: return "client-surface";
            case Outcome::NoShape: return "no-shape";
            case Outcome::NoOutput: return "no-output";
        }
        return "unknown";
    }

    std::string loggableName(std::string_view name) {
        constexpr size_t kMax  = 48;
        const auto       plain = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'; };
        if (name.size() > kMax || !std::ranges::all_of(name, plain))
            return "<other>";
        return std::string{name};
    }

    CRefreshGate::CRefreshGate(events::Duration minInterval) : m_minInterval(minInterval) {}

    SGateDecision CRefreshGate::request(events::TimePoint now) {
        if (m_waiting) {
            ++m_folded;
            return {.action = GateAction::Fold};
        }
        if (!m_lastRun || now - *m_lastRun >= m_minInterval) {
            m_lastRun = now;
            ++m_runs;
            return {.action = GateAction::Now};
        }
        m_waiting = true;
        return {.action = GateAction::Arm, .delay = *m_lastRun + m_minInterval - now};
    }

    bool CRefreshGate::fire(events::TimePoint now) {
        if (!m_waiting)
            return false;
        m_waiting = false;
        m_lastRun = now;
        ++m_runs;
        return true;
    }

    void CRefreshGate::reset() {
        m_lastRun.reset();
        m_waiting = false;
    }

    bool CRefreshGate::waiting() const {
        return m_waiting;
    }

    uint64_t CRefreshGate::runs() const {
        return m_runs;
    }

    uint64_t CRefreshGate::folded() const {
        return m_folded;
    }

} // namespace gf::cursor
