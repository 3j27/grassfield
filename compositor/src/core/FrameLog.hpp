#pragma once

// Presented-frame timestamps per monitor (ADR-0006 gate P3: "≥ 95 % frames < 16.7 ms during dock magnification, Mission
// Control open/close, Launchpad open"; the method needs presentation times, not render-thread times). The plugin records
// the time of every presented frame of each monitor (Hyprland's CMonitor::m_events.presented, the output's presentation
// feedback) in a ring; `hyprctl grassfield-frames` returns them; tests/visual/presented-frames.sh turns them into frame
// pacing over the window of a real shell animation. Pure (no Hyprland include): unit-tested in compositor/tests/FrameLogTest.cpp.
// For attribution, each monitor also keeps the CPU span of every frame Hyprland rendered (a long interval with a long render
// is the compositor's cost; a long interval with a late render is a client that committed late), and the plugin marks the
// phases of its own animations (the Overview's opening, open, closing, closed) on the same clock.

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::frames {

    // `hyprctl grassfield-frames` (exact name, no argument): what was recorded.
    inline constexpr std::string_view kHyprctlCommand = "grassfield-frames";
    // `hyprctl grassfield-frames-start` (exact name, no argument): record for the next kMaxRecordingMs.
    inline constexpr std::string_view kHyprctlStartCommand = "grassfield-frames-start";

    // Nothing is recorded unless a measurement asked for it, and never for long (review of part B, 2026-10-24: frame times
    // on the lock screen give the typing rhythm away, each key redrawing the password dots): a start request records for
    // this long, a new one extends it. While the session is locked nothing is recorded and what was recorded is dropped.
    inline constexpr uint64_t kMaxRecordingMs = 60'000;

    class CRecording {
      public:
        // A start request at `nowMs`: recording until nowMs + kMaxRecordingMs.
        void     start(uint64_t nowMs);
        void     stop();
        // Recording at `nowMs` (not past the bound; a clock that went backwards stops it).
        bool     active(uint64_t nowMs) const;
        uint64_t untilMs() const;

      private:
        uint64_t m_startMs = 0;
        uint64_t m_untilMs = 0;
    };

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

        // Forgets every timestamp (the session locked).
        void clear();

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

    // One frame Hyprland rendered for a monitor: when it began (render.preChecks) and the CPU time to RENDER_POST (the
    // frame's whole render, the plugin's draws included; the GPU's own time is not in it).
    struct RenderSpan {
        uint64_t beginUs = 0;
        uint64_t cpuUs   = 0;

        bool     operator==(const RenderSpan&) const = default;
    };

    // The last kCapacity spans (anything with a `beginUs`) in time order: a span that does not begin after the newest is
    // refused.
    template <typename Span>
    class CSpanRingOf {
      public:
        bool push(const Span& span) {
            if (m_any && span.beginUs <= m_last)
                return false;
            m_slots[m_next] = span;
            m_next          = (m_next + 1) % kCapacity;
            if (m_size < kCapacity)
                ++m_size;
            m_last = span.beginUs;
            m_any  = true;
            return true;
        }

        // Oldest first.
        std::vector<Span> snapshot() const {
            std::vector<Span> out;
            out.reserve(m_size);
            const size_t first = (m_next + kCapacity - m_size) % kCapacity;
            for (size_t i = 0; i < m_size; ++i)
                out.push_back(m_slots[(first + i) % kCapacity]);
            return out;
        }

        void clear() {
            m_next = 0;
            m_size = 0;
            m_last = 0;
            m_any  = false;
        }

        size_t size() const {
            return m_size;
        }

      private:
        std::vector<Span> m_slots = std::vector<Span>(kCapacity);
        size_t            m_next  = 0;
        size_t            m_size  = 0;
        uint64_t          m_last  = 0;
        bool              m_any   = false;
    };
    using CSpanRing = CSpanRingOf<RenderSpan>;

    // Phase marks of the plugin's animations ("overview-opening", ...): the last kMaxMarks, in time order (a mark older
    // than the newest is refused), each name cut at kMaxMarkBytes.
    inline constexpr size_t kMaxMarks     = 64;
    inline constexpr size_t kMaxMarkBytes = 32;

    struct Mark {
        uint64_t    us = 0;
        std::string what;

        bool        operator==(const Mark&) const = default;
    };

    class CMarkRing {
      public:
        bool              push(uint64_t us, std::string_view what);
        std::vector<Mark> snapshot() const;
        void              clear();

      private:
        std::vector<Mark> m_slots = std::vector<Mark>(kMaxMarks);
        size_t            m_next  = 0;
        size_t            m_size  = 0;
        uint64_t          m_last  = 0;
    };

    // The compositor thread's own time outside the renders, for attribution (integrator review of a6d04df: a main-loop
    // stall before a render shows only as a late render, which reads as a client's late frame). While recording, the plugin
    // beats on the event loop every kBeatUs; a beat more than kStallUs past its due time shows the loop was held from then
    // to the beat (stallOf). The plugin also records its own work outside a render, each from its start to its end: the
    // shared edge's drag (its motions and the frames it applies, tiling.md TL30), as RenderSpans (the start and the length).
    inline constexpr uint64_t kBeatUs  = 4'000;
    inline constexpr uint64_t kStallUs = 2'000;

    // A stall of the event loop: from the beat's due time, its length, and the CPU time the compositor's main thread used
    // from the previous beat to this one (the stall and at most kBeatUs before it; integrator nested pass of ce82fd3: is a
    // compositor-caused frame the compositor's work or the thread waiting, descheduled under load?). Little CPU: the thread
    // was waiting; about the length: it was working.
    struct Stall {
        uint64_t beginUs  = 0;
        uint64_t lengthUs = 0;
        uint64_t cpuUs    = 0;

        bool     operator==(const Stall&) const = default;
    };
    using CStallRing = CSpanRingOf<Stall>;

    // The stall a beat due at `dueUs` and run at `nowUs` shows (`cpuUs`: the main thread's CPU time since the previous
    // beat), or nullopt when it was on time (within kStallUs).
    std::optional<Stall> stallOf(uint64_t dueUs, uint64_t nowUs, uint64_t cpuUs);

    struct LoopRecords {
        uint64_t                beats = 0; // beats run since the recording started (0: the loop was not probed)
        std::vector<Stall>      stalls;
        std::vector<RenderSpan> work;
    };

    struct MonitorFrames {
        std::string             name;
        double                  refreshHz = 0; // the mode's refresh rate (0 when unknown)
        uint64_t                total     = 0;
        std::vector<uint64_t>   presentedUs;
        std::vector<RenderSpan> renders;
    };

    // {"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[{"name":"GF-REF","refreshHz":60,
    //  "total":1234,"presented":[...],"renders":[[beginUs,cpuUs],...]}],"marks":[{"t":us,"what":"overview-opening"}],
    //  "loop":{"beats":N,"stalls":[[beginUs,lengthUs,cpuUs],...],"work":[[beginUs,lengthUs],...]}}.
    // Names are JSON-escaped and cut at kMaxNameBytes (on a UTF-8 boundary); at most kMaxMonitors monitors; a refresh rate
    // that is not finite and positive is written as 0.
    std::string framesJson(std::span<const MonitorFrames> monitors, std::span<const Mark> marks = {}, const LoopRecords& loop = {});

} // namespace gf::frames
