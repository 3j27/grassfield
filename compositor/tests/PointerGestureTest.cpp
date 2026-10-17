#include "core/PointerGesture.hpp"

#include <gtest/gtest.h>

#include <cstdint>

using gf::input::CPointerGestureTracker;

namespace {
    constexpr uint32_t kLeft  = 0x110; // BTN_LEFT
    constexpr uint32_t kRight = 0x111; // BTN_RIGHT
} // namespace

TEST(PointerGesture, ClaimedPressOwnsItsRelease) {
    CPointerGestureTracker t;
    EXPECT_FALSE(t.onPress(kLeft));
    t.claim(kLeft, true);
    const auto r = t.onRelease(kLeft);
    EXPECT_TRUE(r.owned);
    EXPECT_TRUE(r.endsGesture);
    EXPECT_FALSE(t.owns(kLeft));
    EXPECT_FALSE(t.gestureButton());
}

TEST(PointerGesture, UnclaimedReleaseIsNotOwned) {
    CPointerGestureTracker t;
    t.onPress(kLeft); // the press went to a client
    const auto r = t.onRelease(kLeft);
    EXPECT_FALSE(r.owned);
    EXPECT_FALSE(r.endsGesture);
}

TEST(PointerGesture, ReleaseWithoutAnyPressIsNotOwned) {
    CPointerGestureTracker t;
    EXPECT_FALSE(t.onRelease(kLeft).owned);
}

TEST(PointerGesture, ImmediateActionPressStillOwnsItsRelease) {
    // Regression (review finding): the double-click press zooms at once and starts no gesture, but its
    // release must still be kept from the client that never saw the press.
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, false);
    EXPECT_FALSE(t.gestureButton());
    const auto r = t.onRelease(kLeft);
    EXPECT_TRUE(r.owned);
    EXPECT_FALSE(r.endsGesture);
}

TEST(PointerGesture, ReleaseOfAnotherButtonIsNotOwned) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    EXPECT_FALSE(t.onRelease(kRight).owned);
    EXPECT_EQ(t.gestureButton(), kLeft);
}

TEST(PointerGesture, PressDuringGestureCancelsIt) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    EXPECT_TRUE(t.onPress(kRight)); // another button: the drag ends
    EXPECT_FALSE(t.gestureButton());
    EXPECT_TRUE(t.owns(kLeft)); // the left release may still arrive and must stay hidden
    EXPECT_FALSE(t.onRelease(kRight).owned);
    EXPECT_TRUE(t.onRelease(kLeft).owned);
}

TEST(PointerGesture, NewPressSupersedesALostRelease) {
    // Regression (review finding): the device that pressed disappears mid-drag; the next click elsewhere
    // must end the drag and its release must reach the client.
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    EXPECT_TRUE(t.onPress(kLeft)); // new press from another device, not consumed by a titlebar
    EXPECT_FALSE(t.gestureButton());
    EXPECT_FALSE(t.owns(kLeft));
    EXPECT_FALSE(t.onRelease(kLeft).owned);
}

TEST(PointerGesture, MotionWithoutHeldButtonsCancelsTheGesture) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    EXPECT_FALSE(t.onMotion(true, true));
    EXPECT_EQ(t.gestureButton(), kLeft);
    EXPECT_TRUE(t.onMotion(false, true));
    EXPECT_FALSE(t.gestureButton());
    EXPECT_FALSE(t.owns(kLeft)); // its release will never come through the normal path
    EXPECT_FALSE(t.onMotion(false, true)); // nothing left to cancel
}

TEST(PointerGesture, MotionAfterTheDeviceDisappearedCancelsTheGesture) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    EXPECT_TRUE(t.onMotion(true, false));
    EXPECT_FALSE(t.gestureButton());
    EXPECT_FALSE(t.owns(kLeft));
}

TEST(PointerGesture, MotionWithoutGestureDoesNothing) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, false);
    EXPECT_FALSE(t.onMotion(false, false));
    EXPECT_TRUE(t.owns(kLeft));
}

TEST(PointerGesture, DropGestureKeepsOwnership) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    t.dropGesture(); // the window closed mid-drag
    EXPECT_FALSE(t.gestureButton());
    const auto r = t.onRelease(kLeft);
    EXPECT_TRUE(r.owned);
    EXPECT_FALSE(r.endsGesture);
}

TEST(PointerGesture, TitlebarReleaseExpectationIsOneShot) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    ASSERT_TRUE(t.onRelease(kLeft).owned);
    t.expectTitlebarRelease(kLeft);
    EXPECT_FALSE(t.takeTitlebarRelease(kRight));
    EXPECT_TRUE(t.takeTitlebarRelease(kLeft));
    EXPECT_FALSE(t.takeTitlebarRelease(kLeft));
}

TEST(PointerGesture, TitlebarReleaseExpectationExpiresOnTheNextButtonEvent) {
    CPointerGestureTracker t;
    t.expectTitlebarRelease(kLeft);
    t.onPress(kRight);
    EXPECT_FALSE(t.takeTitlebarRelease(kLeft));

    t.expectTitlebarRelease(kLeft);
    t.onRelease(kRight);
    EXPECT_FALSE(t.takeTitlebarRelease(kLeft));
}

TEST(PointerGesture, ResetForgetsEverything) {
    CPointerGestureTracker t;
    t.onPress(kLeft);
    t.claim(kLeft, true);
    t.claim(kRight, false);
    t.expectTitlebarRelease(kLeft);
    t.reset();
    EXPECT_FALSE(t.owns(kLeft));
    EXPECT_FALSE(t.owns(kRight));
    EXPECT_FALSE(t.gestureButton());
    EXPECT_FALSE(t.takeTitlebarRelease(kLeft));
}
