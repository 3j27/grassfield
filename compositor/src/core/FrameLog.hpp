#pragma once

// Presented-frame timestamps per monitor (ADR-0006 gate P3: "≥ 95 % frames < 16.7 ms during dock magnification, Mission
// Control open/close, Launchpad open"; the method needs presentation times, not render-thread times). The plugin records
// the time of every presented frame of each monitor (Hyprland's CMonitor::m_events.presented, the output's presentation
// feedback) in a ring; `hyprctl grassfield-frames` returns them; tests/compositor/frame_pacing.sh turns them into frame
// pacing over the window of a real shell animation. Pure (no Hyprland include): unit-tested in tests/FrameLogTest.cpp.

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::frames {

    // `hyprctl grassfield-frames` (exact name, no argument).
    inline constexpr std::string_view kHyprctlCommand = "grassfield-frames";

    // Frames kept per monitor: 1024 is about 17 s at 60 Hz, more than any of the P3 animations plus its margins.
    inline constexpr size_t kCapacity = 1024;

    // Monitors reported at most (a name longer than kMaxNameBytes is cut).
    inline constexpr size_t kMaxMonitors  = 16;
    inline constexpr size_t kMaxNameBytes = 64;

    // A fixed ring of timestamps (microseconds of CLOCK_MONOTONIC, the clock std::chrono::steady_clock reads on Linux and
    // Python's time.monotonic reads): the oldest is overwritten once full. A timestamp older than the newest is refused
    // (a clock that went backwards, or a duplicate presentation event): the ring stays in time order.
    class CRing {
      public:
        // False when refused (not after the newest).
        bool push(uint64_t us);

        // Oldest first.
        std::vector<uint64_t> snapshot() const;

        size_t size() const {
            return m_size;
        }

        // Every timestamp accepted since the start (the ring holds the last kCapacity of them).
        uint64_t total() const {
            return m_total;
        }

      private:
        std::vector<uint64_t> m_slots = std::vector<uint64_t>(kCapacity, 0);
        size_t                m_next  = 0;
        size_t                m_size  = 0;
        uint64_t              m_total = 0;
        uint64_t              m_last  = 0;
    };

    struct MonitorFrames {
        std::string           name;
        double                refreshHz = 0; // the mode's refresh rate (0 when unknown)
        uint64_t              total     = 0;
        std::vector<uint64_t> presentedUs;
    };

    // {"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[{"name":"GF-REF","refreshHz":60,
    //  "total":1234,"presented":[...]}]}. Names are JSON-escaped and cut at kMaxNameBytes (on a UTF-8 boundary); at most
    // kMaxMonitors monitors; a refresh rate that is not finite and positive is written as 0.
    std::string framesJson(std::span<const MonitorFrames> monitors);

} // namespace gf::frames
