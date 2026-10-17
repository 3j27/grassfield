#include "core/Minimize.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <limits>
#include <vector>

using namespace gf::minimize;

namespace {
    constexpr double NaN = std::numeric_limits<double>::quiet_NaN();
    constexpr double Inf = std::numeric_limits<double>::infinity();

    // The nested dev layout: WAYLAND-1 1440x900 at (0,0), GF-REF 1920x1080 at (1440,0).
    constexpr std::array<Box, 2> MONITORS = {{{0, 0, 1440, 900}, {1440, 0, 1920, 1080}}};

    void expectBox(const Box& actual, const Box& expected, double eps = 1e-9) {
        EXPECT_NEAR(actual.x, expected.x, eps);
        EXPECT_NEAR(actual.y, expected.y, eps);
        EXPECT_NEAR(actual.w, expected.w, eps);
        EXPECT_NEAR(actual.h, expected.h, eps);
    }
} // namespace

TEST(MinimizeAddress, AcceptsHyprlandAddresses) {
    EXPECT_EQ(parseAddress("0x605cc1156d90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("605cc1156d90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("0X605CC1156D90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("ffffffffffffffff"), 0xffffffffffffffffULL);
}

TEST(MinimizeAddress, RejectsAnythingElse) {
    EXPECT_FALSE(parseAddress(""));
    EXPECT_FALSE(parseAddress("0x"));
    EXPECT_FALSE(parseAddress("0"));                  // null pointer
    EXPECT_FALSE(parseAddress("1ffffffffffffffff"));  // 17 digits
    EXPECT_FALSE(parseAddress("0x12 "));
    EXPECT_FALSE(parseAddress(" 0x12"));
    EXPECT_FALSE(parseAddress("-12"));
    EXPECT_FALSE(parseAddress("+12"));
    EXPECT_FALSE(parseAddress("12g"));
    EXPECT_FALSE(parseAddress("0x12\"); hl.dsp.exit() --"));
    EXPECT_FALSE(parseAddress(std::string_view("12\0ab", 5)));
}

TEST(MinimizeTarget, DockTileInsideAMonitorIsValid) {
    EXPECT_TRUE(isValidTarget({1440 + 900, 1080 - 70, 52, 52}, MONITORS));
    EXPECT_TRUE(isValidTarget({0, 0, 1, 1}, MONITORS));
    EXPECT_TRUE(isValidTarget({1440 - 52, 900 - 52, 52, 52}, MONITORS)); // flush with the bottom-right corner
    EXPECT_TRUE(isValidTarget({-0.5, 0, 52, 52}, MONITORS));             // within the 1 px tolerance
}

TEST(MinimizeTarget, RejectsOutsideStraddlingDegenerateAndNonFinite) {
    EXPECT_FALSE(isValidTarget({1440 - 20, 100, 52, 52}, MONITORS)); // straddles two monitors
    EXPECT_FALSE(isValidTarget({100, 880, 52, 52}, MONITORS));       // below WAYLAND-1
    EXPECT_FALSE(isValidTarget({-100, -100, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 0, 0}, MONITORS)); // the shell's "no Dock" rectangle
    EXPECT_FALSE(isValidTarget({100, 100, -52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 0.5, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({1500, 0, 1100, 100}, MONITORS)); // larger than kMaxTargetSide
    EXPECT_FALSE(isValidTarget({NaN, 100, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, Inf, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 52, NaN}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 52, 52}, {}));                                // no monitors
    EXPECT_FALSE(isValidTarget({100, 100, 52, 52}, std::vector<Box>{{0, 0, NaN, 900}})); // broken monitor
}

TEST(MinimizeGeometry, FitInsideKeepsTheAspectRatioCentered) {
    // 702x530 window into a 52x52 tile: width-limited, centered vertically.
    const Box fit = fitInside({0, 0, 702, 530}, {100, 200, 52, 52});
    EXPECT_NEAR(fit.w, 52, 1e-9);
    EXPECT_NEAR(fit.h, 52.0 * 530 / 702, 1e-9);
    EXPECT_NEAR(fit.x, 100, 1e-9);
    EXPECT_NEAR(fit.y + (fit.h / 2), 226, 1e-9);
    // Tall window: height-limited, centered horizontally.
    const Box tall = fitInside({0, 0, 300, 600}, {0, 0, 50, 50});
    expectBox(tall, {12.5, 0, 25, 50});
    // Degenerate source: the target itself.
    expectBox(fitInside({0, 0, 0, 10}, {1, 2, 3, 4}), {1, 2, 3, 4});
}

TEST(MinimizeGeometry, LerpAndMapBox) {
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 0.0), {0, 0, 100, 100});
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 1.0), {100, 200, 10, 20});
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 0.5), {50, 100, 55, 60});
    // The shadow box around a 100x100 window, mapped onto a half-size window elsewhere.
    expectBox(mapBox({-10, -10, 120, 120}, {0, 0, 100, 100}, {500, 500, 50, 50}), {495, 495, 60, 60});
    expectBox(mapBox({1, 2, 3, 4}, {0, 0, 0, 0}, {10, 10, 5, 5}), {11, 12, 3, 4}); // degenerate source: translate only
}

TEST(MinimizeEasing, CubicBezierEndpointsAndShape) {
    const CCubicBezier easeIn{0.4, 0.0, 1.0, 1.0};
    EXPECT_DOUBLE_EQ(easeIn(0.0), 0.0);
    EXPECT_DOUBLE_EQ(easeIn(1.0), 1.0);
    EXPECT_DOUBLE_EQ(easeIn(-1.0), 0.0); // clamped
    EXPECT_DOUBLE_EQ(easeIn(2.0), 1.0);
    double previous = 0.0;
    for (int i = 1; i < 100; ++i) {
        const double t = i / 100.0;
        const double v = easeIn(t);
        EXPECT_LT(v, t) << "ease-in stays below the diagonal at t=" << t;
        EXPECT_GE(v, previous) << "monotonic at t=" << t;
        previous = v;
    }
    const CCubicBezier linear{0.0, 0.0, 1.0, 1.0};
    const CCubicBezier linear2{0.25, 0.25, 0.75, 0.75};
    EXPECT_NEAR(linear2(0.3), 0.3, 1e-6);
    EXPECT_NEAR(linear(0.5), 0.5, 1e-6);
}

TEST(MinimizeEasing, RestoreCurveIsTheTimeReverseOfMinimize) {
    const auto in  = curve(Kind::Minimize);
    const auto out = curve(Kind::Restore);
    for (int i = 0; i <= 20; ++i) {
        const double t = i / 20.0;
        EXPECT_NEAR(out(t), 1.0 - in(1.0 - t), 1e-6) << "t=" << t;
        EXPECT_GE(out(t), t - 1e-9) << "ease-out stays above the diagonal";
    }
}

TEST(MinimizeFrames, MinimizeShrinksIntoTheTileAndFadesAtTheEnd) {
    const Box window{2050, 236, 702, 530};
    const Box tile = fitInside(window, {2300, 1010, 52, 52});
    EXPECT_DOUBLE_EQ(durationMs(Kind::Minimize), 300.0);

    const Frame start = frameAt(Kind::Minimize, window, tile, 0);
    expectBox(start.box, window);
    EXPECT_FLOAT_EQ(start.alpha, 1.F);
    EXPECT_FALSE(start.done);

    const Frame mid = frameAt(Kind::Minimize, window, tile, 150);
    EXPECT_GT(mid.box.w, tile.w);
    EXPECT_LT(mid.box.w, window.w);
    // Ease-in: at half time the window has covered less than half of the way.
    EXPECT_GT(mid.box.w, (window.w + tile.w) / 2);
    EXPECT_FLOAT_EQ(mid.alpha, 1.F);
    // Uniform scale: the aspect ratio never changes.
    EXPECT_NEAR(mid.box.w / mid.box.h, window.w / window.h, 1e-9);

    const Frame fading = frameAt(Kind::Minimize, window, tile, 270); // t = 0.9, fade over the last 20 %
    EXPECT_NEAR(fading.alpha, 0.5F, 1e-5);

    const Frame end = frameAt(Kind::Minimize, window, tile, 300);
    expectBox(end.box, tile);
    EXPECT_FLOAT_EQ(end.alpha, 0.F);
    EXPECT_TRUE(end.done);
    EXPECT_TRUE(frameAt(Kind::Minimize, window, tile, 5000).done);
}

TEST(MinimizeFrames, RestoreGrowsFromTheTileAndFadesInAtTheStart) {
    const Box window{2050, 236, 702, 530};
    const Box tile = fitInside(window, {2300, 1010, 52, 52});
    const Frame start = frameAt(Kind::Restore, tile, window, 0);
    expectBox(start.box, tile);
    EXPECT_FLOAT_EQ(start.alpha, 0.F);
    EXPECT_NEAR(frameAt(Kind::Restore, tile, window, 30).alpha, 0.5F, 1e-5);
    const Frame mid = frameAt(Kind::Restore, tile, window, 150);
    EXPECT_GT(mid.box.w, (window.w + tile.w) / 2); // ease-out: more than half of the way at half time
    EXPECT_FLOAT_EQ(mid.alpha, 1.F);
    const Frame end = frameAt(Kind::Restore, tile, window, 300);
    expectBox(end.box, window);
    EXPECT_FLOAT_EQ(end.alpha, 1.F);
    EXPECT_TRUE(end.done);
}

TEST(MinimizeFrames, NonFiniteTimeEndsTheAnimation) {
    EXPECT_TRUE(frameAt(Kind::Minimize, {0, 0, 10, 10}, {0, 0, 1, 1}, NaN).done);
    EXPECT_FALSE(frameAt(Kind::Minimize, {0, 0, 10, 10}, {0, 0, 1, 1}, -50).done); // clock skew: start
}

TEST(MinimizeSnapshot, IdentityDrawsTheTextureOverTheMonitor) {
    // Snapshot of GF-REF (1920x1080 at (1440,0), scale 1); the window drawn where it was.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1, .texW = 1920, .texH = 1080};
    expectBox(textureBox(snap, snap.visible, 1440, 0, 1), {0, 0, 1920, 1080});
}

TEST(MinimizeSnapshot, MatchesHyprlandsFadeoutMathOnTheSameMonitor) {
    // CWindowFadeout::renderBox: scale = size / sourceSize; x = (pos - mon) * s - sourcePos * s * scale.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1.5, .texW = 2880, .texH = 1620};
    const Box               dst{2100, 300, 351, 265}; // half size
    const Box               tex = textureBox(snap, dst, 1440, 0, 1.5);
    const double            k   = 0.5;
    expectBox(tex, {((2100 - 1440) * 1.5) - ((2050 - 1440) * 1.5 * k), (300 * 1.5) - (236 * 1.5 * k), 2880 * k, 1620 * k});
    // The window region of the texture lands exactly on dst (in pixels).
    EXPECT_NEAR(tex.x + ((2050 - 1440) * 1.5 * k), (2100 - 1440) * 1.5, 1e-9);
}

TEST(MinimizeSnapshot, DrawingOnAnotherMonitorUsesThatMonitorsOriginAndScale) {
    // Snapshot taken on GF-REF, drawn on WAYLAND-1 (origin 0,0, scale 2) into a Dock tile there.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1, .texW = 1920, .texH = 1080};
    const Box               dst = fitInside(snap.visible, {700, 840, 52, 52});
    const Box               tex = textureBox(snap, dst, 0, 0, 2);
    const double            k   = (dst.w * 2) / 702.0;
    // The window region (at 610,236 px in the texture) maps onto dst in WAYLAND-1's pixels.
    EXPECT_NEAR(tex.x + (610 * k), dst.x * 2, 1e-9);
    EXPECT_NEAR(tex.y + (236 * k), dst.y * 2, 1e-9);
    EXPECT_NEAR(tex.w, 1920 * k, 1e-9);
}

TEST(MinimizeSnapshot, Intersects) {
    EXPECT_TRUE(intersects({0, 0, 10, 10}, {5, 5, 10, 10}));
    EXPECT_FALSE(intersects({0, 0, 10, 10}, {10, 0, 10, 10})); // touching edges share no area
    EXPECT_FALSE(intersects({0, 0, 0, 10}, {0, 0, 10, 10}));
}
