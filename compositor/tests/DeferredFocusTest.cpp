#include "core/DeferredFocus.hpp"
#include "core/Stages.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <type_traits>
#include <utility>
#include <vector>

using namespace gf::deferredfocus;

// The shared deferred-focus decisions (Stages ST10/ST23 and the overview focus). The Stages cases in StagesTest.cpp run
// through the gf::stages aliases, which must stay the very same types and functions.
TEST(DeferredFocusRefusal, WaitsWhileHyprlandRefusesOrTheHolderKeepsTheKeyboard) {
    EXPECT_FALSE(mustWait({})) << "nothing refuses: the focus may be made";
    EXPECT_TRUE(mustWait({.locked = true, .exclusive = false, .holderKeeps = false})) << "the session lock";
    EXPECT_TRUE(mustWait({.locked = false, .exclusive = true, .holderKeeps = false})) << "an Exclusive layer is mapped";
    EXPECT_TRUE(mustWait({.locked = false, .exclusive = false, .holderKeeps = true})) << "the layer kept the keyboard (on_demand)";
}

TEST(DeferredFocusShared, StagesUsesTheSharedDecisions) {
    static_assert(std::is_same_v<gf::stages::PressRecord, PressRecord>);
    static_assert(std::is_same_v<gf::stages::PressContext, PressContext>);
    static_assert(std::is_same_v<gf::stages::FocusCause, FocusCause>);
    static_assert(std::is_same_v<gf::stages::FocusOrigin, FocusOrigin>);
    const auto press = gf::stages::recordPress({.exclusive = true, .onExclusive = false, .under = 0x42});
    EXPECT_EQ(press.scope, PressScope::UntilFocus);
    EXPECT_TRUE(clickFromPress(press, 0x42));
    EXPECT_EQ(gf::stages::focusOrigin(FocusCause::Click, false, true), FocusOrigin::UserChoice);
}

TEST(DeferredFocusPress, APressIntoTheLayerChoosesNothing) {
    EXPECT_EQ(recordPress({.exclusive = true, .onExclusive = true, .under = 0x10}).scope, PressScope::None);
    EXPECT_FALSE(clickFromPress(recordPress({.exclusive = true, .onExclusive = true, .under = 0x10}), 0x10));
}

// ---- CLaterOn: one event-loop callback, owned RAII (audit ARCH-21) ----

namespace {
    // A fake event loop: scheduled callbacks by sequence, and the sequences removed.
    struct SFakeLoop {
        static inline std::vector<std::pair<uint64_t, std::function<void()>>> pending;
        static inline std::vector<uint64_t>                                   removed;
        static inline uint64_t                                                next      = 1;
        static inline bool                                                    available = true;

        static std::optional<uint64_t> post(const std::function<void()>& fn) {
            if (!available)
                return std::nullopt;
            pending.emplace_back(next, fn);
            return next++;
        }

        static void remove(uint64_t seq) {
            removed.push_back(seq);
            std::erase_if(pending, [seq](const auto& p) { return p.first == seq; });
        }

        // Runs every callback scheduled so far, as the loop's idle pass does.
        static void runAll() {
            auto now = std::exchange(pending, {});
            for (auto& [seq, fn] : now)
                fn();
        }

        static void reset() {
            pending.clear();
            removed.clear();
            next      = 1;
            available = true;
        }
    };

    using CFakeLater = CLaterOn<SFakeLoop>;
} // namespace

TEST(DeferredFocusLater, DestroyingTheOwnerRemovesAScheduledCallback) {
    SFakeLoop::reset();
    int calls = 0;
    {
        CFakeLater later;
        EXPECT_TRUE(later.schedule([&calls] { ++calls; }));
        EXPECT_TRUE(later.scheduled());
        ASSERT_EQ(SFakeLoop::pending.size(), 1U);
    } // destroyed with its callback pending (e.g. a library unloaded without stop())
    EXPECT_EQ(SFakeLoop::removed, std::vector<uint64_t>{1}) << "the destructor removes the callback";
    EXPECT_TRUE(SFakeLoop::pending.empty());
    SFakeLoop::runAll();
    EXPECT_EQ(calls, 0) << "the loop never calls into a destroyed owner";
}

TEST(DeferredFocusLater, DestroyingAfterTheCallbackRanRemovesNothing) {
    SFakeLoop::reset();
    int calls = 0;
    {
        CFakeLater later;
        later.schedule([&calls] { ++calls; });
        SFakeLoop::runAll();
        EXPECT_EQ(calls, 1);
        EXPECT_FALSE(later.scheduled()) << "the callback forgets its sequence before it runs";
    }
    EXPECT_TRUE(SFakeLoop::removed.empty());
}

TEST(DeferredFocusLater, CoalescesCancelsAndReschedulesFromItsCallback) {
    SFakeLoop::reset();
    int        calls = 0;
    CFakeLater later;
    EXPECT_TRUE(later.schedule([&calls] { ++calls; }));
    EXPECT_FALSE(later.schedule([&calls] { calls += 100; })) << "one callback at a time";
    later.cancel();
    EXPECT_FALSE(later.scheduled());
    EXPECT_EQ(SFakeLoop::removed, std::vector<uint64_t>{1});
    later.cancel(); // nothing scheduled: nothing removed
    EXPECT_EQ(SFakeLoop::removed.size(), 1U);
    // A callback that schedules again (an attempt that must retry).
    EXPECT_TRUE(later.schedule([&] {
        ++calls;
        later.schedule([&calls] { calls += 10; });
    }));
    SFakeLoop::runAll();
    EXPECT_EQ(calls, 1);
    EXPECT_TRUE(later.scheduled());
    SFakeLoop::runAll();
    EXPECT_EQ(calls, 11);
    EXPECT_FALSE(later.scheduled());
}

TEST(DeferredFocusLater, ClearForgetsWithoutRemovingAndNoLoopSchedulesNothing) {
    SFakeLoop::reset();
    {
        CFakeLater later;
        later.schedule([] {});
        later.clear(); // start() after a stop() that cancelled: the sequence is stale
        EXPECT_FALSE(later.scheduled());
    }
    EXPECT_TRUE(SFakeLoop::removed.empty()) << "a cleared sequence is never removed (it may belong to another call now)";
    SFakeLoop::reset();
    SFakeLoop::available = false;
    CFakeLater later;
    EXPECT_FALSE(later.schedule([] {})) << "no event loop: nothing scheduled";
    EXPECT_FALSE(later.scheduled());
    SFakeLoop::available = true;
}
