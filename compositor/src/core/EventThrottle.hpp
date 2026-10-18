#pragma once

// Rate limits for plugin -> shell events and for log lines that clients can trigger (R11, R13; spec FR24).
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/EventThrottleTest.cpp); time is
// passed in, and the glue (Ipc.cpp) arms a Hyprland event loop timer for CEventThrottle::nextDue().
//
// Why: Hyprland writes each socket2 event to every subscriber at once and queues it when the subscriber's socket is
// full; a subscriber whose queue overflows is disconnected ("Socket2 fd N overflowed event queue, removing"), and
// Quickshell then receives no Hyprland event at all until the shell restarts. Client requests
// (org_kde_kwin_appmenu.set_address, titlebar clicks from a virtual pointer, Lua verbs over the hyprctl socket) can
// arrive by the thousand within one dispatch, so the plugin must never post one event per request.

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace gf::events {

    using Clock     = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    using Duration  = Clock::duration;

    // What an event describes. Events of one channel and id replace each other: only the latest one matters.
    enum class Channel : uint8_t {
        Capabilities,    // id 0
        MinimizeRequest, // id: window address
        MinimizeState,   // id: window address (minimized / restored: two values of one state)
        Appmenu,         // id: window address
        Overview,        // id 0 (one overview state)
    };

    struct Key {
        Channel  channel = Channel::Capabilities;
        uint64_t id      = 0;

        bool     operator==(const Key&) const = default;
    };

    // Token bucket: starts full with `capacity` tokens and gains one every `period` (never more than `capacity`).
    class CTokenBucket {
      public:
        CTokenBucket(size_t capacity, Duration period);

        // Takes a token if one is available at `now`.
        bool      take(TimePoint now);

        // Tokens available at `now`.
        size_t    available(TimePoint now) const;

        // When a token is available: `now` if one is, else when the next one arrives.
        TimePoint nextToken(TimePoint now) const;

      private:
        struct SState {
            size_t                   tokens = 0;
            std::optional<TimePoint> last; // the last refill instant; unset until the first use
        };
        SState   at(TimePoint now) const;

        size_t   m_capacity;
        Duration m_period;
        SState   m_state;
    };

    struct ThrottleLimits {
        Duration keyInterval = std::chrono::milliseconds(100); // one key posts at most once per interval (10/s)
        size_t   burst       = 32;                             // all keys together: `burst` posts at once,
        Duration refill      = std::chrono::milliseconds(20);  // then one per `refill` (50/s)
    };

    // Coalesces events per key. An event is posted at once when its key has not posted within `keyInterval` and the
    // global budget has a token; otherwise it waits, and a newer event of the same key replaces it (the latest
    // wins). A waiting event is never dropped: it is posted as soon as its key's interval has elapsed and a token
    // is available (trailing edge), so the final state of a burst always reaches the shell, at most `keyInterval`
    // after the burst when the budget allows. Waiting events are posted in the order of their latest submission:
    // a key that keeps changing goes behind keys that changed once.
    class CEventThrottle {
      public:
        explicit CEventThrottle(ThrottleLimits limits = {});

        // Queues `payload` under `key` and returns what is due now, in posting order (`payload` included when its
        // key and the budget allow it).
        std::vector<std::string> submit(Key key, std::string payload, TimePoint now);

        // What became due by `now` (timer callback).
        std::vector<std::string> due(TimePoint now);

        // When the next waiting event becomes due (never before `now`); nullopt when nothing waits.
        std::optional<TimePoint> nextDue(TimePoint now) const;

        // Every waiting event regardless of the limits, in posting order, and forgets every key (unload).
        std::vector<std::string> drain();

        // Events waiting to be posted.
        size_t                   waiting() const;

        // Totals since construction: events posted, events replaced by a newer one of the same key before they
        // were posted.
        uint64_t                 posted() const;
        uint64_t                 coalesced() const;

      private:
        struct SEntry {
            Key                        key;
            std::optional<TimePoint>   lastPost;
            std::optional<std::string> payload; // waiting event
            uint64_t                   seq = 0; // order of the latest submission
        };

        bool                ready(const SEntry& e, TimePoint now) const;
        void                prune(TimePoint now);

        ThrottleLimits      m_limits;
        CTokenBucket        m_budget;
        std::vector<SEntry> m_entries;
        uint64_t            m_seq       = 0;
        uint64_t            m_posted    = 0;
        uint64_t            m_coalesced = 0;
    };

    // Log lines caused by client requests: lets `burst` lines through, then one per `period`.
    class CLogLimiter {
      public:
        CLogLimiter(size_t burst, Duration period);

        // nullopt: do not write the line (it is counted). Otherwise write it; the value is the number of lines
        // held back since the previous written one (to append "N similar lines suppressed").
        std::optional<uint64_t> admit(TimePoint now);

      private:
        CTokenBucket m_bucket;
        uint64_t     m_suppressed = 0;
    };

    // Counters that are worth a log line: 1, 10, 100, 1000, ... (a per-object request counter logs at these).
    bool isLogMilestone(uint64_t count);

} // namespace gf::events
