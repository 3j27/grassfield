#include "EventThrottle.hpp"

#include <algorithm>
#include <utility>

namespace gf::events {

    // ---- CTokenBucket -----------------------------------------------------------------------------------------------

    CTokenBucket::CTokenBucket(size_t capacity, Duration period) :
        m_capacity(std::max<size_t>(capacity, 1)), m_period(std::max(period, Duration{1})), m_state{.tokens = m_capacity, .last = std::nullopt} {}

    CTokenBucket::SState CTokenBucket::at(TimePoint now) const {
        SState s = m_state;
        if (!s.last || s.tokens >= m_capacity) {
            s.last = now; // full: nothing accrues
            return s;
        }
        if (now <= *s.last)
            return s;
        const auto gained = static_cast<uint64_t>((now - *s.last) / m_period);
        if (gained == 0)
            return s;
        if (gained >= m_capacity - s.tokens) {
            s.tokens = m_capacity;
            s.last   = now;
        } else {
            s.tokens += static_cast<size_t>(gained);
            *s.last += m_period * static_cast<Duration::rep>(gained);
        }
        return s;
    }

    bool CTokenBucket::take(TimePoint now) {
        m_state = at(now);
        if (m_state.tokens == 0)
            return false;
        --m_state.tokens;
        return true;
    }

    size_t CTokenBucket::available(TimePoint now) const {
        return at(now).tokens;
    }

    TimePoint CTokenBucket::nextToken(TimePoint now) const {
        const SState s = at(now);
        if (s.tokens > 0 || !s.last)
            return now;
        return std::max(now, *s.last + m_period);
    }

    // ---- CEventThrottle ---------------------------------------------------------------------------------------------

    CEventThrottle::CEventThrottle(ThrottleLimits limits) : m_limits(limits), m_budget(limits.burst, limits.refill) {}

    bool CEventThrottle::ready(const SEntry& e, TimePoint now) const {
        return e.payload && (!e.lastPost || (now >= *e.lastPost && now - *e.lastPost >= m_limits.keyInterval));
    }

    void CEventThrottle::prune(TimePoint now) {
        // A key that posted more than an interval ago and waits for nothing constrains nothing any more.
        std::erase_if(m_entries, [&](const SEntry& e) { return !e.payload && (!e.lastPost || (now >= *e.lastPost && now - *e.lastPost >= m_limits.keyInterval)); });
    }

    std::vector<std::string> CEventThrottle::submit(Key key, std::string payload, TimePoint now) {
        auto it = std::ranges::find(m_entries, key, &SEntry::key);
        if (it == m_entries.end()) {
            m_entries.push_back(SEntry{.key = key, .lastPost = std::nullopt, .payload = std::nullopt, .seq = 0});
            it = std::prev(m_entries.end());
        }
        if (it->payload)
            ++m_coalesced;
        it->payload = std::move(payload);
        it->seq     = ++m_seq;
        return due(now);
    }

    std::vector<std::string> CEventThrottle::due(TimePoint now) {
        std::vector<SEntry*> candidates;
        for (auto& e : m_entries) {
            if (ready(e, now))
                candidates.push_back(&e);
        }
        std::ranges::sort(candidates, {}, &SEntry::seq);

        std::vector<std::string> out;
        for (auto* e : candidates) {
            auto& payload = e->payload; // set: ready() checked it
            if (!payload || !m_budget.take(now))
                break; // the rest waits for the next token, in the same order
            out.push_back(std::move(*payload));
            payload.reset();
            e->lastPost = now;
            ++m_posted;
        }
        prune(now);
        return out;
    }

    std::optional<TimePoint> CEventThrottle::nextDue(TimePoint now) const {
        std::optional<TimePoint> best;
        const TimePoint          token = m_budget.nextToken(now);
        for (const auto& e : m_entries) {
            if (!e.payload)
                continue;
            const TimePoint keyReady = e.lastPost ? *e.lastPost + m_limits.keyInterval : now;
            const TimePoint t        = std::max({keyReady, token, now});
            if (!best || t < *best)
                best = t;
        }
        return best;
    }

    std::vector<std::string> CEventThrottle::drain() {
        std::vector<SEntry*> waitingEntries;
        for (auto& e : m_entries) {
            if (e.payload)
                waitingEntries.push_back(&e);
        }
        std::ranges::sort(waitingEntries, {}, &SEntry::seq);
        std::vector<std::string> out;
        out.reserve(waitingEntries.size());
        for (auto* e : waitingEntries) {
            if (auto& payload = e->payload; payload)
                out.push_back(std::move(*payload));
        }
        m_posted += out.size();
        m_entries.clear();
        return out;
    }

    size_t CEventThrottle::waiting() const {
        return static_cast<size_t>(std::ranges::count_if(m_entries, [](const SEntry& e) { return e.payload.has_value(); }));
    }

    uint64_t CEventThrottle::posted() const {
        return m_posted;
    }

    uint64_t CEventThrottle::coalesced() const {
        return m_coalesced;
    }

    // ---- logging ----------------------------------------------------------------------------------------------------

    CLogLimiter::CLogLimiter(size_t burst, Duration period) : m_bucket(burst, period) {}

    std::optional<uint64_t> CLogLimiter::admit(TimePoint now) {
        if (!m_bucket.take(now)) {
            ++m_suppressed;
            return std::nullopt;
        }
        return std::exchange(m_suppressed, 0);
    }

    bool isLogMilestone(uint64_t count) {
        if (count == 0)
            return false;
        while (count % 10 == 0)
            count /= 10;
        return count == 1;
    }

} // namespace gf::events
