// Windows that draw their own chrome (ADR-0015, docs/specs/compositor.md "Plugin work item: client chrome"): the tag
// predicate (P1), the feature (P2), the band (P3), the zoomed drag (P4), Option+click full screen and its glyph (P6) and
// the one token source of the lights (P7). Test names state the user-visible rule.

#include "core/ClientChrome.hpp"
#include "core/Protocol.hpp"
#include "core/Stages.hpp"
#include "core/Theme.hpp"
#include "core/ThemeTokens.hpp"
#include "core/TitlebarLayout.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <set>
#include <string>
#include <vector>

using namespace gf::chrome;

// ---- P1 ----

TEST(ClientChromeTag, TheSessionRulesTagMarksTheWindow) {
    EXPECT_TRUE(hasClientChromeTag({"grassfield-client-chrome"}));
    EXPECT_TRUE(hasClientChromeTag({"grassfield-client-chrome*"})) << "a dynamic (rule-set) tag prints with a trailing *";
    EXPECT_TRUE(hasClientChromeTag({"other", "grassfield-client-chrome*", "third*"}));
}

TEST(ClientChromeTag, NoOtherTagCounts) {
    EXPECT_FALSE(hasClientChromeTag({}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome-x"}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrom"}));
    EXPECT_FALSE(hasClientChromeTag({"Grassfield-Client-Chrome"})) << "exact, case-sensitive";
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome**"})) << "one star only";
    EXPECT_FALSE(hasClientChromeTag({"*grassfield-client-chrome"}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome "}));
}

TEST(ClientChromeTag, TheTagIsTheShellsAndTheSessionRules) {
    // shell/overview/ClientChrome.js TAG and config/hypr/grassfield/windows.lua `tag = "+grassfield-client-chrome"`
    // (tests/shell/client_chrome_rules.sh compares them with the spec).
    EXPECT_EQ(kTag, "grassfield-client-chrome");
}

// ---- P2 ----

TEST(ClientChromeFeature, AdvertisedOnlyWhenItsListenersAreRegistered) {
    using namespace gf::gfc;
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","client-chrome"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, false, false, false, false, false, false, false, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appearance","client-chrome"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true, true, true, true, true, true, false)).find("client-chrome"),
              std::string::npos);
    EXPECT_EQ(kFeatureClientChrome, "client-chrome") << "the name the shell's ClientChrome.js FEATURE waits for";
}

// ---- P3 ----

TEST(ClientChromeBand, NoTitlebarBandAboveSuchAWindow) {
    EXPECT_EQ(band(true), 0.0);
    EXPECT_EQ(band(false), gf::theme::kTitlebarHeight);
}

TEST(ClientChromeBand, StagesThumbnailOfSuchAWindowHasNoBand) {
    using namespace gf::stages;
    const Box                 tile{16, 120, 180, 130};
    const std::vector<Box>    surfaces{{500, 300, 700, 500}};
    const std::vector<double> none{band(true)};
    const auto                r = thumbRects(tile, surfaces, none);
    ASSERT_EQ(r.size(), 1U);
    const double s = std::min(180.0 / 700, 130.0 / 500);
    EXPECT_NEAR(r[0].w, 700 * s, 1e-9) << "fitted on the surface alone";
    EXPECT_NEAR(r[0].y, tile.y + ((130 - (500 * s)) / 2), 1e-9) << "centred with no band above it";
    const auto withBar = thumbRects(tile, surfaces);
    EXPECT_LT(withBar[0].h, r[0].h) << "a window with the plugin's strip is fitted with its band, so it is smaller";
}

TEST(ClientChromeBand, StagesBandsArePerWindowAndBadValuesFallBack) {
    using namespace gf::stages;
    const Box                 tile{0, 0, 300, 300};
    const std::vector<Box>    surfaces{{0, 0, 200, 100}, {0, 0, 200, 100}, {0, 0, 200, 100}};
    const std::vector<double> bands{0.0, std::nan(""), -5.0}; // the client-chrome window first, then two invalid bands
    const auto                r     = thumbRects(tile, surfaces, bands);
    const auto                plain = thumbRects(tile, surfaces);
    ASSERT_EQ(r.size(), 3U);
    EXPECT_NE(r[0].y, plain[0].y) << "band 0 for the first window";
    EXPECT_EQ(r[1], plain[1]) << "NaN: the titlebar band";
    EXPECT_EQ(r[2], plain[2]) << "negative: the titlebar band";
    const std::vector<double> shortList{0.0};
    EXPECT_EQ(thumbRects(tile, surfaces, shortList)[2], plain[2]) << "a shorter list: the titlebar band for the rest";
}

TEST(ClientChromeBand, StripTargetsPassTheBandsOn) {
    using namespace gf::stages;
    const std::vector<Box>    tiles{{16, 120, 180, 130}};
    const std::vector<Box>    surfaces{{500, 300, 700, 500}};
    const std::vector<double> none{0.0};
    const Box                 monitor{0, 0, 1920, 1080};
    const auto                t = stripTargets(0, tiles, false, false, monitor, surfaces, none);
    ASSERT_EQ(t.size(), 1U);
    EXPECT_EQ(t[0].to, thumbRects(tiles[0], surfaces, none)[0]);
}

// ---- P4 ----

TEST(ClientChromeZoomedDrag, AMoveRequestAnswersTheRecordedPressOfTheSameWindow) {
    const ZoomedPress press{.window = 0xabc, .zoomed = {0, 30, 1920, 1050}, .x = 960, .y = 56, .timeMs = 1000};
    EXPECT_TRUE(moveAnswersPress(press, 0xabc, true, 1010));
    EXPECT_TRUE(moveAnswersPress(press, 0xabc, true, 1000 + kMovePressMaxAgeMs));
    EXPECT_FALSE(moveAnswersPress(press, 0xdef, true, 1010)) << "another window";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, false, 1010)) << "the button was released";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, true, 1001 + kMovePressMaxAgeMs)) << "too late";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, true, 999)) << "a clock that went backwards";
    EXPECT_FALSE(moveAnswersPress(std::nullopt, 0xabc, true, 1010)) << "no press recorded";
    EXPECT_FALSE(moveAnswersPress(ZoomedPress{}, 0, true, 0)) << "no window";
}

TEST(ClientChromeZoomedDrag, TheWindowComesBackUnderThePointerAtTheSamePlaceInItsRow) {
    // Zoomed: the surface fills 1920 x 1050 below the menu bar; the press is in the toolbar row, three quarters across.
    const ZoomedPress press{.window = 1, .zoomed = {0, 30, 1920, 1050}, .x = 1440, .y = 56, .timeMs = 0};
    const auto        box = unzoomedBox(press, 800, 500, 1450, 70); // the pointer moved by (10, 14) before the request
    EXPECT_DOUBLE_EQ(box.w, 800);
    EXPECT_DOUBLE_EQ(box.h, 500);
    EXPECT_DOUBLE_EQ(box.x, 1450 - (0.75 * 800)) << "the same horizontal fraction";
    EXPECT_DOUBLE_EQ(box.y, 70 - 26) << "the same height below the top edge: the toolbar row stays under the pointer";
}

TEST(ClientChromeZoomedDrag, APressBelowTheRestoredHeightKeepsThePointerOnTheWindow) {
    const ZoomedPress press{.window = 1, .zoomed = {0, 30, 1920, 1050}, .x = 100, .y = 900, .timeMs = 0};
    const auto        box = unzoomedBox(press, 800, 500, 100, 900);
    EXPECT_DOUBLE_EQ(box.y, 900 - 500) << "never below the restored window";
}

// ---- P6 ----

TEST(ClientChromeZoomLight, OptionClickIsTrueFullScreen) {
    EXPECT_EQ(zoomAction(false, false, false), ZoomAction::Zoom);
    EXPECT_EQ(zoomAction(true, false, false), ZoomAction::Unzoom);
    EXPECT_EQ(zoomAction(false, false, true), ZoomAction::EnterFullscreen);
    EXPECT_EQ(zoomAction(true, false, true), ZoomAction::EnterFullscreen) << "from zoomed too";
    EXPECT_EQ(zoomAction(false, true, false), ZoomAction::LeaveFullscreen);
    EXPECT_EQ(zoomAction(false, true, true), ZoomAction::LeaveFullscreen) << "the light of a full-screen window leaves it";
}

TEST(ClientChromeZoomLight, TheGlyphShowsTheArrowsWhileOptionIsHeld) {
    EXPECT_TRUE(zoomGlyphIsArrows(true));
    EXPECT_FALSE(zoomGlyphIsArrows(false));
}

TEST(ClientChromeZoomLight, TheArrowsAreTwoTrianglesAtOppositeCorners) {
    using namespace gf::titlebar;
    const int  n    = 16;
    const auto mask = glyphMask(Button::Zoom, n, 0.12 * 14, true);
    ASSERT_EQ(mask.size(), static_cast<size_t>(n * n));
    const auto at = [&](int x, int y) { return mask[(static_cast<size_t>(y) * n) + static_cast<size_t>(x)]; };
    EXPECT_EQ(at(0, n - 1), 255) << "bottom-left corner filled";
    EXPECT_EQ(at(n - 1, 0), 255) << "top-right corner filled";
    EXPECT_EQ(at(0, 0), 0) << "top-left corner empty";
    EXPECT_EQ(at(n - 1, n - 1), 0) << "bottom-right corner empty";
    EXPECT_EQ(at(n / 2, n / 2), 0) << "the middle is empty: two arrows, not a block";
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x)
            EXPECT_EQ(at(x, y), at(n - 1 - x, n - 1 - y)) << "point symmetry at " << x << "," << y;
    }
    EXPECT_NE(glyphMask(Button::Zoom, n, 0.12 * 14, false), mask) << "the + without Alt";
    EXPECT_EQ(glyphMask(Button::Close, n, 0.12 * 14, true), glyphMask(Button::Close, n, 0.12 * 14)) << "only the zoom light changes";
}

// ---- P7 ----

TEST(ClientChromeTokens, ThePluginsLightsAreTheAppsLights) {
    namespace t = gf::theme::tokens;
    using namespace gf::theme;
    EXPECT_EQ(kButtonDiameter, t::kWindowLightDiameter);
    EXPECT_EQ(kButtonSpacing, t::kWindowLightGap);
    EXPECT_EQ(kTitlebarHeight, t::kWindowTitlebarHeight);
    EXPECT_EQ(kButtonInsetLeft, t::kWindowTitlebarLightInset);
    EXPECT_NEAR(kButtonHitSlop, t::kWindowLightHitSlop, 1e-3);
    EXPECT_EQ(kTitlePadding, t::kWindowTitleGap);
    EXPECT_EQ(kGlyphRatio, t::kWindowGlyphRatio);
    EXPECT_EQ(kGlyphStroke, t::kWindowGlyphStroke);
    EXPECT_FLOAT_EQ(kGlyphColor.a, static_cast<float>(t::kWindowGlyphOpacity));
    const auto same = [](const Rgba& c, uint32_t hex) {
        const Rgba want = fromHex(hex);
        return c.r == want.r && c.g == want.g && c.b == want.b;
    };
    EXPECT_TRUE(same(kCloseColor, t::kWindowCloseColor));
    EXPECT_TRUE(same(kMinimizeColor, t::kWindowMinimizeColor));
    EXPECT_TRUE(same(kZoomColor, t::kWindowZoomColor));
    EXPECT_TRUE(same(titlebarPalette(Appearance::Dark).inactiveLight, t::kWindowInactiveLightDark));
    EXPECT_TRUE(same(titlebarPalette(Appearance::Light).inactiveLight, t::kWindowInactiveLightLight));
}
