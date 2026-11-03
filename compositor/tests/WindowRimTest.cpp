// The dark appearance's light inner rim (core/WindowRim.hpp; ADR-0024 note 2026-11-03): one ring of Hyprland's border
// shader inside every window's frame, 1 pt in whole device pixels, white 0.10 per point (0.08 not key). Test names state the
// user-visible rule. The ring's pixels are computed with the arithmetic of Hyprland 0.56.2's shaders
// (/usr/include/hyprland/src/render/shaders/border.glsl.inc and rounding.glsl.inc, the border as renderBorder sets it up):
// a geometry change that breaks the rim on the corner arcs, or lets it out of the window's shape, fails here.

#include "core/WindowRim.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <limits>
#include <numbers>
#include <sstream>
#include <string>

namespace {
    using gf::rim::Box;
    using gf::rim::Ring;

    constexpr double kPower = 2.6; // decoration.rounding_power (config/hypr/grassfield/looknfeel.lua)
    // The window's radius as Hyprland 0.56.2 draws it: CWindow::rounding() is decoration.rounding (20) x rounding_power / 2
    // ("perceived roundness", read from the binary), 26 pt; the plugin reads it from the window (w->rounding()).
    constexpr double kRounding = 20.0 * kPower / 2.0;
    constexpr std::array<float, 4> kScales{1.F, 1.25F, 1.5F, 2.F};

    // rounding.glsl: SMOOTHING_CONSTANT and GLSL's smoothstep(0, 1, x).
    constexpr double kSmoothing = std::numbers::pi / 5.34665792551;
    double smoothstep01(double x) {
        const double t = std::clamp(x, 0.0, 1.0);
        return t * t * (3.0 - (2.0 * t));
    }
    double pnorm(double x, double y) {
        return std::pow(std::pow(std::max(x, 0.0), kPower) + std::pow(std::max(y, 0.0), kPower), 1.0 / kPower);
    }

    // The window's rounding radius in device pixels as Hyprland gives it to its shaders (an int: rounding * scale).
    int roundingPx(float scale) {
        return static_cast<int>(kRounding * scale);
    }

    // border.glsl getBorder(): the ring's coverage at the device pixel (ix, iy), its centre at (ix + 0.5, iy + 0.5), for the
    // box, radius and width renderBorder derives from the ring (the box grown by the width, round + width, outerRound).
    double ringAlpha(const Ring& r, int ix, int iy) {
        const double t  = r.widthPx;
        const double bx = r.inner.x - t;
        const double by = r.inner.y - t;
        const double bw = r.inner.w + (2.0 * t);
        const double bh = r.inner.h + (2.0 * t);
        const double px = ix + 0.5;
        const double py = iy + 0.5;
        if (px < bx || py < by || px >= bx + bw || py >= by + bh)
            return 0.0; // outside the quad
        const double radius      = r.round + (r.round != 0 ? t : 0.0);
        const double radiusOuter = r.outerRound;
        const double cx          = std::abs(px - (bx + (bw / 2.0)));
        const double cy          = std::abs(py - (by + (bh / 2.0)));
        const double inX         = cx - ((bw / 2.0) - radius) + (1.0 / bw);
        const double inY         = cy - ((bh / 2.0) - radius) + (1.0 / bh);
        const double outX        = cx - ((bw / 2.0) - radiusOuter) + (1.0 / bw);
        const double outY        = cy - ((bh / 2.0) - radiusOuter) + (1.0 / bh);
        if (std::min(inX, inY) > 0.0 && radius > 0.0) {
            const double dist      = pnorm(inX, inY);
            const double distOuter = pnorm(outX, outY);
            const double h         = t / 2.0;
            if (dist < radius - h)
                return smoothstep01((dist - radius + t + kSmoothing) / (kSmoothing * 2.0));
            if (std::min(outX, outY) > 0.0)
                return 1.0 - smoothstep01((distOuter - radiusOuter + kSmoothing) / (kSmoothing * 2.0));
            if (distOuter < radiusOuter - h)
                return 1.0;
        }
        const double lx       = px - bx;
        const double ly       = py - by;
        const double smallest = std::min({ly, bh - ly, lx, bw - lx});
        return smallest > t ? 0.0 : 1.0;
    }

    // rounding.glsl rounding(): the window surface's own coverage at the device pixel (ix, iy) (the frame's box, its corner
    // radius): the window's shape.
    double shapeAlpha(const Box& frame, int radius, int ix, int iy) {
        const double px = ix + 0.5;
        const double py = iy + 0.5;
        if (px < frame.x || py < frame.y || px >= frame.x + frame.w || py >= frame.y + frame.h)
            return 0.0;
        const double cx = std::abs(px - (frame.x + (frame.w / 2.0))) - ((frame.w / 2.0) - radius) + (1.0 / frame.w);
        const double cy = std::abs(py - (frame.y + (frame.h / 2.0))) - ((frame.h / 2.0) - radius) + (1.0 / frame.h);
        if (cx + cy <= radius)
            return 1.0;
        const double dist = pnorm(cx, cy);
        if (dist > radius + kSmoothing)
            return 0.0;
        return 1.0 - smoothstep01((dist - radius + kSmoothing) / (kSmoothing * 2.0));
    }

    // A Settings-sized window (640 x 400 pt) with the plugin's 32-pt titlebar above it, on GF-REF.
    constexpr Box kSurface{.x = 640, .y = 372, .w = 640, .h = 400};
    constexpr double kBar = 32;
} // namespace

TEST(WindowRim, ItsTokensAreMacOs27sRim) {
    // 1 pt of white at 0.10 on the key window, 0.08 on the others (Appearance Dark release captures).
    EXPECT_EQ(gf::theme::tokens::kWindowRimDarkWidth, 1);
    EXPECT_DOUBLE_EQ(gf::theme::tokens::kWindowRimDarkActiveOpacity, 0.10);
    EXPECT_DOUBLE_EQ(gf::theme::tokens::kWindowRimDarkInactiveOpacity, 0.08);
}

TEST(WindowRim, OnlyTheDarkAppearanceHasARim) {
    using gf::rim::WindowState;
    using gf::theme::Appearance;
    EXPECT_EQ(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Dark, .appearanceKnown = true, .active = true}), 0.10);
    EXPECT_EQ(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Dark, .appearanceKnown = true, .active = false}), 0.08);
    EXPECT_FALSE(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Light, .appearanceKnown = true, .active = true})) << "nothing changes in light";
    EXPECT_FALSE(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Light, .appearanceKnown = true, .active = false}));
}

TEST(WindowRim, AFullScreenWindowOrOneWithoutEdgesHasNone) {
    using gf::rim::WindowState;
    using gf::theme::Appearance;
    EXPECT_FALSE(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Dark, .appearanceKnown = true, .active = true, .fullscreen = true})) << "macOS: no edge in full screen";
    EXPECT_FALSE(gf::rim::opacityPerPt(WindowState{.appearance = Appearance::Dark, .appearanceKnown = true, .active = true, .edged = false}))
        << "an X11 window without borders, decorate = false";
}

TEST(WindowRim, NoneUntilTheShellHasSaidTheAppearance) {
    // A plugin (re)loaded in a light session starts on the default (dark) appearance until the shell's push: no rim then,
    // so none flashes on the light windows (gate C2).
    using gf::rim::WindowState;
    EXPECT_FALSE(gf::rim::opacityPerPt(WindowState{.appearance = gf::theme::Appearance::Dark, .appearanceKnown = false, .active = true}));
    EXPECT_TRUE(gf::rim::opacityPerPt(WindowState{.appearance = gf::theme::Appearance::Dark, .appearanceKnown = true, .active = true}));
}

TEST(WindowRim, ByDefaultTheAppearanceIsNotKnown) {
    EXPECT_FALSE(gf::rim::opacityPerPt(gf::rim::WindowState{.active = true})) << "a state built without the shell's word draws nothing";
}

TEST(WindowRim, TheShellsPushMakesTheAppearanceKnownAndSaysWhetherToRedraw) {
    gf::theme::PushedAppearance pushed;
    EXPECT_FALSE(pushed.known);
    EXPECT_EQ(pushed.current, gf::theme::kDefaultAppearance);
    EXPECT_TRUE(pushed.push(gf::theme::Appearance::Dark)) << "the first push redraws, even with the default's value";
    EXPECT_TRUE(pushed.known);
    EXPECT_FALSE(pushed.push(gf::theme::Appearance::Dark)) << "the same again: nothing to redraw";
    EXPECT_TRUE(pushed.push(gf::theme::Appearance::Light));
    EXPECT_EQ(pushed.current, gf::theme::Appearance::Light);
}

TEST(WindowRim, AReloadStartsAsAFreshLoadSoALightSessionNeverGetsADarkRimBeforeThePush) {
    // Review of 5597c201: Hyprland keeps an unloaded plugin's library mapped, so its statics survive a reload. Unloaded in
    // dark, the session turned light, reloaded: without the reset the rim drew dark until the shell's push.
    gf::theme::PushedAppearance pushed;
    pushed.push(gf::theme::Appearance::Dark);
    pushed.reset(); // teardown()
    EXPECT_FALSE(pushed.known);
    EXPECT_EQ(pushed.current, gf::theme::kDefaultAppearance);
    EXPECT_FALSE(gf::rim::opacityPerPt(
        gf::rim::WindowState{.appearance = pushed.current, .appearanceKnown = pushed.known, .active = true}))
        << "no rim between the reload and the shell's push";
    EXPECT_TRUE(pushed.push(gf::theme::Appearance::Light)) << "the push after the reload redraws";
    EXPECT_FALSE(gf::rim::opacityPerPt(gf::rim::WindowState{.appearance = pushed.current, .appearanceKnown = pushed.known, .active = true}));
}

TEST(WindowRim, TheUnloadResetsTheAppearanceAndTheRimsGlobals) {
    // The glue cannot run here: read main.cpp's teardown() and check it resets both, after the rims are removed.
    std::ifstream in(std::filesystem::path{GF_PLUGIN_SOURCE_DIR} / "main.cpp");
    ASSERT_TRUE(in.good());
    std::stringstream text;
    text << in.rdbuf();
    const std::string source = text.str();
    const auto        begin  = source.find("void teardown()");
    ASSERT_NE(begin, std::string::npos);
    const auto end = source.find("\n    }\n", begin);
    ASSERT_NE(end, std::string::npos);
    const std::string body  = source.substr(begin, end - begin);
    const auto        rims  = body.find("removeAllRims()");
    const auto        reset = body.find("appearance.reset()");
    const auto        glob  = body.find("CGrassfieldRim::resetGlobals()");
    ASSERT_NE(rims, std::string::npos);
    EXPECT_NE(reset, std::string::npos) << "teardown() must reset the pushed appearance";
    EXPECT_NE(glob, std::string::npos) << "teardown() must reset the rims' globals";
    EXPECT_GT(reset, rims) << "after the rims are gone";
    EXPECT_GT(glob, rims);
}

TEST(WindowRim, ItIsOnePointInWholeDevicePixelsAsHyprlandsBorder) {
    EXPECT_EQ(gf::rim::widthPx(1, 1.F), 1);
    EXPECT_EQ(gf::rim::widthPx(1, 1.25F), 1) << "the owner's eDP-1: one device pixel, 0.8 pt";
    EXPECT_EQ(gf::rim::widthPx(1, 1.5F), 2) << "roundf(1.5)";
    EXPECT_EQ(gf::rim::widthPx(1, 2.F), 2) << "macOS's two device pixels at 2 px per pt";
    EXPECT_EQ(gf::rim::widthPx(1, 1.75F), 2);
    EXPECT_EQ(gf::rim::widthPx(0, 1.25F), 0);
    EXPECT_EQ(gf::rim::widthPx(1, 0.F), 0);
}

TEST(WindowRim, ItKeepsMacOs27sLightPerPointAtEveryScale) {
    for (const float s : kScales) {
        for (const double perPt : {0.10, 0.08}) {
            const double px = gf::rim::pixelOpacity(perPt, 1, s);
            EXPECT_NEAR(px * gf::rim::widthPx(1, s) / s, perPt, 1e-12) << "scale " << s;
        }
    }
    EXPECT_NEAR(gf::rim::pixelOpacity(0.10, 1, 1.25F), 0.125, 1e-12) << "one device pixel holds 1.25 times less of a point";
    EXPECT_NEAR(gf::rim::pixelOpacity(0.08, 1, 1.25F), 0.10, 1e-12);
    EXPECT_NEAR(gf::rim::pixelOpacity(0.10, 1, 1.F), 0.10, 1e-12);
    EXPECT_NEAR(gf::rim::pixelOpacity(0.10, 1, 1.5F), 0.075, 1e-12);
    EXPECT_NEAR(gf::rim::pixelOpacity(0.10, 1, 2.F), 0.10, 1e-12);
    EXPECT_DOUBLE_EQ(gf::rim::pixelOpacity(0.10, 0, 1.25F), 0.0);
    EXPECT_DOUBLE_EQ(gf::rim::pixelOpacity(0.9, 1, 1.25F), 1.0) << "never more than opaque";
}

TEST(WindowRim, ItRunsAlongTheTopOfThePluginsBarNotUnderItsHairline) {
    const Box frame = gf::rim::frameOf(kSurface, kBar);
    EXPECT_DOUBLE_EQ(frame.y, kSurface.y - kBar) << "the frame's top is the bar's top";
    EXPECT_DOUBLE_EQ(frame.h, kSurface.h + kBar);
    EXPECT_DOUBLE_EQ(frame.x, kSurface.x);
    EXPECT_DOUBLE_EQ(frame.w, kSurface.w);
    const Ring r = gf::rim::ring(gf::rim::snap(frame, 1.25), roundingPx(1.25F), 1, 1.25F);
    ASSERT_TRUE(r.valid);
    const int hairline = static_cast<int>(std::lround(kSurface.y * 1.25)) - 1; // the bar's last device row, its rule
    const int midX     = static_cast<int>((kSurface.x + (kSurface.w / 2)) * 1.25);
    EXPECT_DOUBLE_EQ(ringAlpha(r, midX, static_cast<int>(std::lround(frame.y * 1.25))), 1.0) << "the bar's first row is the rim";
    EXPECT_DOUBLE_EQ(ringAlpha(r, midX, hairline), 0.0) << "nothing under the hairline";
    EXPECT_DOUBLE_EQ(ringAlpha(r, midX, hairline + 1), 0.0) << "nor on the client's top row";
}

TEST(WindowRim, AWindowWithoutTheBarHasItsSurfaceAsItsFrame) {
    const Box frame = gf::rim::frameOf(kSurface, 0);
    EXPECT_DOUBLE_EQ(frame.y, kSurface.y);
    EXPECT_DOUBLE_EQ(frame.h, kSurface.h);
    EXPECT_DOUBLE_EQ(gf::rim::frameOf(kSurface, -5).y, kSurface.y) << "no negative band";
}

TEST(WindowRim, TheFrameIsSnappedToDevicePixelsAsHyprlandPlacesTheWindow) {
    // Whole logical pixels at 1.25: (640, 340) 640 x 432 -> (800, 425) 800 x 540.
    const Box a = gf::rim::snap(Box{.x = 640, .y = 340, .w = 640, .h = 432}, 1.25);
    EXPECT_DOUBLE_EQ(a.x, 800);
    EXPECT_DOUBLE_EQ(a.y, 425);
    EXPECT_DOUBLE_EQ(a.w, 800);
    EXPECT_DOUBLE_EQ(a.h, 540);
    // Off the 4-pt grid of 1.25: x 641 -> 801.25 -> 801; the right edge 1601.25 -> 1601, so 800 wide (hyprutils keeps the
    // rounded right edge, not round(w)).
    const Box b = gf::rim::snap(Box{.x = 641, .y = 341, .w = 639, .h = 431}, 1.25);
    EXPECT_DOUBLE_EQ(b.x, 801);
    EXPECT_DOUBLE_EQ(b.y, 426);
    EXPECT_DOUBLE_EQ(b.w, std::round((641 + 639) * 1.25 - 801)); // 799
    EXPECT_DOUBLE_EQ(b.h, std::round((341 + 431) * 1.25 - 426)); // 539
    for (const float s : kScales) {
        for (int step = 0; step < 30; ++step) {
            const double x = step / 10.0;
            const Box    c = gf::rim::snap(Box{.x = 100 + x, .y = 50 + x, .w = 300 + x, .h = 200}, s);
            EXPECT_DOUBLE_EQ(c.x, std::round(c.x)) << "whole device pixels";
            EXPECT_DOUBLE_EQ(c.w, std::round(c.w));
            EXPECT_LE(std::abs((c.x + c.w) - ((100 + x + 300 + x) * s)), 1.0) << "the right edge where the window's is";
        }
    }
}

TEST(WindowRim, TheRingIsTheFramesFirstDevicePixelsWithTheWindowsCorner) {
    for (const float s : kScales) {
        const Box  frame = gf::rim::snap(gf::rim::frameOf(kSurface, kBar), s);
        const Ring r     = gf::rim::ring(frame, roundingPx(s), 1, s);
        ASSERT_TRUE(r.valid) << "scale " << s;
        const int t = gf::rim::widthPx(1, s);
        EXPECT_EQ(r.widthPx, t);
        EXPECT_EQ(r.borderPt, 1) << "Hyprland scales the border's points itself";
        // renderBorder grows `inner` by the width: the ring's outer edge is the frame, on whole pixels.
        EXPECT_DOUBLE_EQ(r.inner.x - t, frame.x);
        EXPECT_DOUBLE_EQ(r.inner.y - t, frame.y);
        EXPECT_DOUBLE_EQ(r.inner.w + (2.0 * t), frame.w);
        EXPECT_DOUBLE_EQ(r.inner.h + (2.0 * t), frame.h);
        EXPECT_EQ(r.outerRound, roundingPx(s)) << "the outer arc is the window's corner (26 pt: rounding 20 at power 2.6)";
        EXPECT_EQ(r.round + t, r.outerRound) << "the inner arc is concentric";
    }
    // At 1.25: 32 px corners (32.5 cut to an int, as Hyprland does), one device pixel; at 2: 52 px, two.
    const Ring a = gf::rim::ring(gf::rim::snap(kSurface, 1.25), roundingPx(1.25F), 1, 1.25F);
    EXPECT_EQ(a.outerRound, 32);
    EXPECT_EQ(a.round, 31);
    const Ring b = gf::rim::ring(gf::rim::snap(kSurface, 2), roundingPx(2.F), 1, 2.F);
    EXPECT_EQ(b.outerRound, 52);
    EXPECT_EQ(b.round, 50);
}

TEST(WindowRim, ASquareWindowGetsASquareRing) {
    const Ring r = gf::rim::ring(Box{.x = 0, .y = 0, .w = 100, .h = 80}, 0, 1, 1.F);
    ASSERT_TRUE(r.valid);
    EXPECT_EQ(r.round, 0);
    EXPECT_EQ(r.outerRound, 0);
    EXPECT_DOUBLE_EQ(ringAlpha(r, 0, 0), 1.0) << "the corner pixel is lit";
}

TEST(WindowRim, NothingIsDrawnWithoutRoomOrWidth) {
    EXPECT_FALSE(gf::rim::ring(Box{.x = 0, .y = 0, .w = 2, .h = 100}, 0, 1, 1.F).valid);
    EXPECT_FALSE(gf::rim::ring(Box{.x = 0, .y = 0, .w = 100, .h = 4}, 25, 1, 2.F).valid);
    EXPECT_FALSE(gf::rim::ring(Box{.x = 0, .y = 0, .w = 100, .h = 100}, 25, 0, 1.25F).valid);
    EXPECT_TRUE(gf::rim::ring(Box{.x = 0, .y = 0, .w = 3, .h = 3}, 0, 1, 1.F).valid);
    // Hyprland's renderBorder asserts on an empty or NaN box: such a frame (a window mid-animation gone wrong) draws nothing.
    EXPECT_FALSE(gf::rim::ring(Box{.x = std::nan(""), .y = 0, .w = 100, .h = 100}, 25, 1, 1.25F).valid);
    EXPECT_FALSE(gf::rim::ring(Box{.x = 0, .y = 0, .w = std::numeric_limits<double>::infinity(), .h = 100}, 25, 1, 1.25F).valid);
    EXPECT_FALSE(gf::rim::ring(Box{.x = 0, .y = 0, .w = 100, .h = -40}, 25, 1, 1.25F).valid);
}

TEST(WindowRim, ItLightsTheFirstDevicePixelsOfEachStraightSideAndNoneFurtherIn) {
    for (const float s : kScales) {
        const Box  frame = gf::rim::snap(gf::rim::frameOf(kSurface, kBar), s);
        const Ring r     = gf::rim::ring(frame, roundingPx(s), 1, s);
        const int  t     = r.widthPx;
        const int  x0    = static_cast<int>(frame.x);
        const int  y0    = static_cast<int>(frame.y);
        const int  x1    = static_cast<int>(frame.x + frame.w) - 1;
        const int  y1    = static_cast<int>(frame.y + frame.h) - 1;
        const int  mx    = static_cast<int>(frame.x + (frame.w / 2));
        const int  my    = static_cast<int>(frame.y + (frame.h / 2));
        for (int k = 0; k < t; ++k) {
            EXPECT_DOUBLE_EQ(ringAlpha(r, x0 + k, my), 1.0) << "left, scale " << s;
            EXPECT_DOUBLE_EQ(ringAlpha(r, x1 - k, my), 1.0) << "right, scale " << s;
            EXPECT_DOUBLE_EQ(ringAlpha(r, mx, y0 + k), 1.0) << "top, scale " << s;
            EXPECT_DOUBLE_EQ(ringAlpha(r, mx, y1 - k), 1.0) << "bottom, scale " << s;
        }
        EXPECT_DOUBLE_EQ(ringAlpha(r, x0 + t, my), 0.0) << "scale " << s;
        EXPECT_DOUBLE_EQ(ringAlpha(r, x1 - t, my), 0.0);
        EXPECT_DOUBLE_EQ(ringAlpha(r, mx, y0 + t), 0.0);
        EXPECT_DOUBLE_EQ(ringAlpha(r, mx, y1 - t), 0.0);
        EXPECT_DOUBLE_EQ(ringAlpha(r, x0 - 1, my), 0.0) << "the contact pixel outside stays Hyprland's border's";
        EXPECT_DOUBLE_EQ(ringAlpha(r, mx, y1 + 1), 0.0);
    }
}

TEST(WindowRim, ItNeverLeavesTheWindowsRoundedShape) {
    // On every pixel of the frame, corners included, the rim covers no more than the window's own surface: nothing in the
    // cut-away corners, where the contact pixel and the shadow are.
    for (const float s : kScales) {
        const Box  frame = gf::rim::snap(gf::rim::frameOf(kSurface, kBar), s);
        const int  R     = roundingPx(s);
        const Ring r     = gf::rim::ring(frame, R, 1, s);
        const int  x0    = static_cast<int>(frame.x);
        const int  y0    = static_cast<int>(frame.y);
        const int  x1    = static_cast<int>(frame.x + frame.w);
        const int  y1    = static_cast<int>(frame.y + frame.h);
        double     worst = 0.0;
        for (int y = y0 - 2; y < y1 + 2; ++y) {
            for (int x = x0 - 2; x < x1 + 2; ++x) {
                const bool nearEdge = x < x0 + R + 2 || x > x1 - R - 3 || y < y0 + R + 2 || y > y1 - R - 3;
                if (nearEdge)
                    worst = std::max(worst, ringAlpha(r, x, y) - shapeAlpha(frame, R, x, y));
            }
        }
        EXPECT_LE(worst, 1e-9) << "scale " << s;
    }
}

TEST(WindowRim, ItIsContinuousRoundTheCornerArcsAtTheWindowsRounding) {
    // macOS 27 keeps the rim continuous round the 20-pt corners; Hyprland's inner glow faded there (34 or less against 62 on
    // the straight edges, ADR-0024 note 2026-11-03). The ring's light per unit of arc length, in 10-degree sectors of the
    // top-left corner (the corner's centre at the radius from both sides), against the straight sides' (the width): within
    // 25 % in every sector, at every scale.
    for (const float s : kScales) {
        const Box  frame = gf::rim::snap(gf::rim::frameOf(kSurface, kBar), s);
        const int  R     = roundingPx(s);
        const Ring r     = gf::rim::ring(frame, R, 1, s);
        const int  t     = r.widthPx;
        const double cx  = frame.x + R;
        const double cy  = frame.y + R;
        // The arc's length per sector: the superellipse of radius R - t / 2 (the ring's middle) at the rounding power.
        const auto point = [&](double deg) {
            const double a  = deg * std::numbers::pi / 180.0;
            const double ux = std::cos(a);
            const double uy = std::sin(a);
            const double n  = std::pow(std::pow(ux, kPower) + std::pow(uy, kPower), 1.0 / kPower);
            const double m  = (R - (t / 2.0)) / n;
            return std::array<double, 2>{m * ux, m * uy};
        };
        std::array<double, 9> light{};
        for (int y = static_cast<int>(frame.y); y < static_cast<int>(cy); ++y) {
            for (int x = static_cast<int>(frame.x); x < static_cast<int>(cx); ++x) {
                const double dx  = cx - (x + 0.5);
                const double dy  = cy - (y + 0.5);
                const double deg = std::atan2(dy, dx) * 180.0 / std::numbers::pi;
                if (deg < 0 || deg >= 90)
                    continue;
                light.at(static_cast<size_t>(deg / 10)) += ringAlpha(r, x, y);
            }
        }
        for (size_t k = 0; k < light.size(); ++k) {
            double length = 0;
            for (int step = 0; step < 100; ++step) {
                const auto p = point((10.0 * static_cast<double>(k)) + (step / 10.0));
                const auto q = point((10.0 * static_cast<double>(k)) + ((step + 1) / 10.0));
                length += std::hypot(q[0] - p[0], q[1] - p[1]);
            }
            const double perLength = light.at(k) / length;
            EXPECT_GT(perLength, 0.75 * t) << "scale " << s << ", sector " << (10 * k) << "-" << (10 * k + 10) << " deg: " << perLength;
            EXPECT_LT(perLength, 1.25 * t) << "scale " << s << ", sector " << (10 * k) << "-" << (10 * k + 10) << " deg: " << perLength;
        }
    }
}
