#include "core/EventThrottle.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

using namespace gf::events;
using namespace std::chrono_literals;

namespace {
    constexpr TimePoint T0 = TimePoint{} + 1000s;

    constexpr uint64_t WINDOW   = 0x55d3c2a0b1f0;
    constexpr uint64_t WINDOW_2 = 0x55d3c2a0c000;

    const Key APPMENU{.channel = Channel::Appmenu, .id = WINDOW};
    const Key APPMENU_2{.channel = Channel::Appmenu, .id = WINDOW_2};
    const Key CAPS{.channel = Channel::Capabilities, .id = 0};

    struct SPost {
        TimePoint   at;
        std::string payload;
    };

    struct SSubmit {
        TimePoint   at;
        Key         key;
        std::string payload;
    };

    // Runs `submits` (in time order) through `t` the way the glue does: after each submit and each timer callback
    // the timer is armed for nextDue(); it fires at that instant. Returns every post with its time.
    std::vector<SPost> simulate(CEventThrottle& t, const std::vector<SSubmit>& submits) {
        std::vector<SPost>       posts;
        std::optional<TimePoint> timer;
        size_t                   i = 0;
        for (int guard = 0; guard < 10'000'000; ++guard) {
            if (i < submits.size() && (!timer || submits[i].at < *timer)) {
                const auto& s = submits[i++];
                for (auto& p : t.submit(s.key, s.payload, s.at))
                    posts.push_back({s.at, std::move(p)});
                timer = t.nextDue(s.at);
                continue;
            }
            if (!timer)
                break; // no submit left, nothing waiting
            const TimePoint at = *timer;
            for (auto& p : t.due(at))
                posts.push_back({at, std::move(p)});
            const auto next = t.nextDue(at);
            EXPECT_TRUE(!next || *next > at) << "timer re-armed for the same instant: busy loop";
            timer = next;
        }
        return posts;
    }

    // Most posts within any window of `width` (posts in time order).
    size_t maxInWindow(const std::vector<SPost>& posts, std::chrono::milliseconds width) {
        size_t best = 0;
        size_t lo   = 0;
        for (size_t hi = 0; hi < posts.size(); ++hi) {
            while (posts[hi].at - posts[lo].at >= width)
                ++lo;
            best = std::max(best, hi - lo + 1);
        }
        return best;
    }
} // namespace

// ---- CTokenBucket ---------------------------------------------------------------------------------------------------

TEST(TokenBucket, StartsFullAndEmpties) {
    CTokenBucket b(3, 20ms);
    EXPECT_EQ(b.available(T0), 3u);
    EXPECT_TRUE(b.take(T0));
    EXPECT_TRUE(b.take(T0));
    EXPECT_TRUE(b.take(T0));
    EXPECT_FALSE(b.take(T0));
    EXPECT_EQ(b.nextToken(T0), T0 + 20ms);
}

TEST(TokenBucket, RefillsOnePerPeriodUpToCapacity) {
    CTokenBucket b(3, 20ms);
    for (int i = 0; i < 3; ++i)
        ASSERT_TRUE(b.take(T0));
    EXPECT_FALSE(b.take(T0 + 19ms));
    EXPECT_TRUE(b.take(T0 + 20ms));
    EXPECT_FALSE(b.take(T0 + 39ms));
    EXPECT_EQ(b.available(T0 + 10s), 3u); // never more than the capacity
}

TEST(TokenBucket, ZeroCapacityOrPeriodAreClamped) {
    CTokenBucket b(0, Duration::zero());
    EXPECT_TRUE(b.take(T0)); // capacity 1: a bucket that never posts would hold events forever
    EXPECT_FALSE(b.take(T0));
    EXPECT_TRUE(b.take(T0 + 1ms));
}

// ---- CEventThrottle: per key ----------------------------------------------------------------------------------------

TEST(EventThrottle, FirstEventIsPostedAtOnce) {
    CEventThrottle t;
    EXPECT_EQ(t.submit(APPMENU, "a", T0), std::vector<std::string>{"a"});
    EXPECT_EQ(t.waiting(), 0u);
    EXPECT_FALSE(t.nextDue(T0).has_value());
}

// The review case: 200 alternating set_address requests on one object within one dispatch.
TEST(EventThrottle, BurstOnOneKeyPostsTwiceAndTheLastOneWins) {
    CEventThrottle           t;
    std::vector<std::string> posted;
    for (int i = 0; i < 200; ++i) {
        const std::string payload = i == 199 ? "final" : (i % 2 ? "/MenuBar/2" : "/MenuBar/1");
        for (auto& p : t.submit(APPMENU, payload, T0))
            posted.push_back(p);
    }
    EXPECT_EQ(posted, std::vector<std::string>{"/MenuBar/1"}); // leading edge
    EXPECT_EQ(t.waiting(), 1u);
    EXPECT_EQ(t.coalesced(), 198u);
    ASSERT_EQ(t.nextDue(T0), T0 + 100ms);
    EXPECT_TRUE(t.due(T0 + 99ms).empty());
    EXPECT_EQ(t.due(T0 + 100ms), std::vector<std::string>{"final"}); // trailing edge: the final state
    EXPECT_EQ(t.waiting(), 0u);
    EXPECT_EQ(t.posted(), 2u);
}

TEST(EventThrottle, QuietKeyPostsAtOnceAgainAfterTheInterval) {
    CEventThrottle t;
    EXPECT_EQ(t.submit(APPMENU, "a", T0).size(), 1u);
    EXPECT_EQ(t.submit(APPMENU, "b", T0 + 100ms), std::vector<std::string>{"b"});
    EXPECT_TRUE(t.submit(APPMENU, "c", T0 + 150ms).empty());
    EXPECT_EQ(t.nextDue(T0 + 150ms), T0 + 200ms);
}

TEST(EventThrottle, KeysAreIndependent) {
    CEventThrottle t;
    EXPECT_EQ(t.submit(APPMENU, "a", T0).size(), 1u);
    EXPECT_EQ(t.submit(APPMENU_2, "b", T0).size(), 1u);
    EXPECT_EQ(t.submit(Key{.channel = Channel::MinimizeState, .id = WINDOW}, "m", T0).size(), 1u);
    EXPECT_EQ(t.submit(Key{.channel = Channel::MinimizeRequest, .id = WINDOW}, "r", T0).size(), 1u);
    EXPECT_EQ(t.submit(CAPS, "c", T0).size(), 1u);
}

// A hostile client at 10 kHz for 5 s: never more than 10 posts per second for its key, and the last request's payload
// is the last post, at most one interval after the spam ends.
TEST(EventThrottle, HardCapPerKeyPerSecondAndFinalStateKept) {
    CEventThrottle       t;
    std::vector<SSubmit> spam;
    spam.reserve(50'000);
    for (int i = 0; i < 50'000; ++i)
        spam.push_back({T0 + std::chrono::microseconds(100) * i, APPMENU, "p" + std::to_string(i)});
    const auto posts = simulate(t, spam);
    ASSERT_FALSE(posts.empty());
    EXPECT_LE(maxInWindow(posts, 1000ms), 10u);
    EXPECT_LE(posts.size(), 51u);
    for (size_t i = 1; i < posts.size(); ++i)
        EXPECT_GE(posts[i].at - posts[i - 1].at, 100ms);
    EXPECT_EQ(posts.back().payload, "p49999");
    EXPECT_LE(posts.back().at - spam.back().at, 100ms);
    EXPECT_EQ(t.waiting(), 0u);
}

// The same with alternating values: the shell may see intermediate values, but always ends with the last one.
TEST(EventThrottle, AlternatingBurstsEndWithTheLastValue) {
    for (const int count : {2, 3, 199, 200, 25'000}) {
        CEventThrottle       t;
        std::vector<SSubmit> spam;
        spam.reserve(static_cast<size_t>(count));
        for (int i = 0; i < count; ++i)
            spam.push_back({T0 + std::chrono::microseconds(2) * i, APPMENU, i == count - 1 ? "final" : (i % 2 ? "b" : "a")});
        const auto posts = simulate(t, spam);
        ASSERT_FALSE(posts.empty()) << count;
        EXPECT_EQ(posts.back().payload, "final") << count;
        EXPECT_LE(posts.size(), 2u) << count; // the whole burst lasts less than one interval
    }
}

// ---- CEventThrottle: global budget ----------------------------------------------------------------------------------

TEST(EventThrottle, GlobalBudgetCapsBurstsAcrossKeysWithoutDroppingAny) {
    CEventThrottle       t; // burst 32, then one per 20 ms
    std::vector<SSubmit> burst;
    for (uint64_t w = 1; w <= 100; ++w)
        burst.push_back({T0, Key{.channel = Channel::Appmenu, .id = w}, "w" + std::to_string(w)});
    const auto posts = simulate(t, burst);
    ASSERT_EQ(posts.size(), 100u); // nothing dropped
    size_t atOnce = 0;
    for (const auto& p : posts)
        atOnce += p.at == T0 ? 1 : 0;
    EXPECT_EQ(atOnce, 32u);
    for (size_t i = 0; i < posts.size(); ++i)
        EXPECT_EQ(posts[i].payload, "w" + std::to_string(i + 1)); // submission order
    EXPECT_EQ(posts.back().at, T0 + 20ms * (100 - 32));
    EXPECT_LE(maxInWindow(posts, 1000ms), 32u + 50u);
}

TEST(EventThrottle, KeyThatKeepsChangingGoesBehindKeysThatChangedOnce) {
    CEventThrottle t(ThrottleLimits{.keyInterval = 100ms, .burst = 1, .refill = 20ms});
    EXPECT_EQ(t.submit(APPMENU_2, "x", T0).size(), 1u); // takes the only token; the next one comes at +20 ms
    EXPECT_TRUE(t.submit(APPMENU, "a1", T0 + 1ms).empty());
    EXPECT_TRUE(t.submit(CAPS, "caps", T0 + 2ms).empty());
    EXPECT_TRUE(t.submit(APPMENU, "a2", T0 + 3ms).empty());
    EXPECT_TRUE(t.submit(APPMENU, "a3", T0 + 4ms).empty());
    EXPECT_EQ(t.coalesced(), 2u);
    // The quiet capabilities event takes the next token, then the latest appmenu value.
    std::vector<SPost>       posts;
    std::optional<TimePoint> at = t.nextDue(T0 + 4ms);
    while (at) {
        for (auto& p : t.due(*at))
            posts.push_back({*at, p});
        at = t.nextDue(*at);
    }
    ASSERT_EQ(posts.size(), 2u);
    EXPECT_EQ(posts[0].payload, "caps");
    EXPECT_EQ(posts[0].at, T0 + 20ms);
    EXPECT_EQ(posts[1].payload, "a3");
    EXPECT_EQ(posts[1].at, T0 + 40ms);
}

// ---- capabilities: the shell's hello retry against a hostile hello flood -------------------------------------------

// The shell sends hello every 250 ms until it gets a capabilities event; a hostile process calls hello() 1000 times
// per second. Capabilities stay at 10 per second at most, and every shell hello is answered within 100 ms.
TEST(EventThrottle, HelloRetryIsAnsweredUnderAHostileHelloFlood) {
    CEventThrottle       t;
    std::vector<SSubmit> submits;
    submits.reserve(3000 + 12);
    for (int ms = 0; ms < 3000; ++ms)
        submits.push_back({T0 + std::chrono::milliseconds(ms) + 500us, CAPS, "caps"}); // hostile, between shell hellos
    std::vector<TimePoint> shellHellos;
    for (int ms = 0; ms < 3000; ms += 250)
        shellHellos.push_back(T0 + std::chrono::milliseconds(ms));
    for (const auto at : shellHellos)
        submits.push_back({at, CAPS, "caps"});
    std::ranges::sort(submits, {}, &SSubmit::at);
    const auto posts = simulate(t, submits);
    EXPECT_LE(maxInWindow(posts, 1000ms), 10u);
    for (const auto hello : shellHellos) {
        const bool answered = std::ranges::any_of(posts, [&](const SPost& p) { return p.at >= hello && p.at - hello <= 100ms; });
        EXPECT_TRUE(answered) << "hello at +" << std::chrono::duration_cast<std::chrono::milliseconds>(hello - T0).count() << " ms";
    }
}

// ---- unload, scheduling ---------------------------------------------------------------------------------------------

TEST(EventThrottle, DrainReturnsEveryWaitingEventInOrderAndForgetsKeys) {
    CEventThrottle t;
    t.submit(APPMENU, "a1", T0);
    t.submit(APPMENU_2, "b1", T0);
    t.submit(APPMENU_2, "b2", T0 + 1ms);
    t.submit(APPMENU, "a2", T0 + 2ms);
    EXPECT_EQ(t.drain(), (std::vector<std::string>{"b2", "a2"}));
    EXPECT_EQ(t.waiting(), 0u);
    EXPECT_FALSE(t.nextDue(T0 + 2ms).has_value());
    EXPECT_EQ(t.submit(APPMENU, "a3", T0 + 3ms), std::vector<std::string>{"a3"}); // keys forgotten
}

TEST(EventThrottle, NextDueIsNeverBeforeNow) {
    CEventThrottle t;
    t.submit(APPMENU, "a1", T0);
    t.submit(APPMENU, "a2", T0);
    EXPECT_EQ(t.nextDue(T0 + 500ms), T0 + 500ms); // a late timer: due at once, not in the past
    EXPECT_EQ(t.due(T0 + 500ms), std::vector<std::string>{"a2"});
}

TEST(EventThrottle, ClockGoingBackwardsDoesNotPostEarlyOrLoseEvents) {
    CEventThrottle t;
    t.submit(APPMENU, "a1", T0);
    EXPECT_TRUE(t.submit(APPMENU, "a2", T0 - 1s).empty());
    EXPECT_EQ(t.nextDue(T0 - 1s), T0 + 100ms);
    EXPECT_EQ(t.due(T0 + 100ms), std::vector<std::string>{"a2"});
}

// ---- logging --------------------------------------------------------------------------------------------------------

TEST(LogLimiter, LetsABurstThroughThenCountsWhatItHoldsBack) {
    CLogLimiter l(3, 1s);
    EXPECT_EQ(l.admit(T0), 0u);
    EXPECT_EQ(l.admit(T0), 0u);
    EXPECT_EQ(l.admit(T0), 0u);
    for (int i = 0; i < 25'000; ++i)
        EXPECT_FALSE(l.admit(T0 + 1ms).has_value());
    EXPECT_FALSE(l.admit(T0 + 999ms).has_value());
    EXPECT_EQ(l.admit(T0 + 1s), 25'001u); // the next written line reports them
    EXPECT_FALSE(l.admit(T0 + 1s).has_value());
}

TEST(LogMilestone, PowersOfTen) {
    EXPECT_FALSE(isLogMilestone(0));
    EXPECT_TRUE(isLogMilestone(1));
    EXPECT_FALSE(isLogMilestone(2));
    EXPECT_FALSE(isLogMilestone(9));
    EXPECT_TRUE(isLogMilestone(10));
    EXPECT_FALSE(isLogMilestone(11));
    EXPECT_FALSE(isLogMilestone(20));
    EXPECT_TRUE(isLogMilestone(100));
    EXPECT_TRUE(isLogMilestone(10'000'000'000ULL));
    size_t lines = 0;
    for (uint64_t n = 1; n <= 25'000; ++n)
        lines += isLogMilestone(n) ? 1 : 0;
    EXPECT_EQ(lines, 5u); // 1, 10, 100, 1000, 10000
}
