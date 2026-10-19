#include "core/DeferredFocus.hpp"
#include "core/Stages.hpp"

#include <gtest/gtest.h>

#include <type_traits>

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
