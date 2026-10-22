#include "core/Genie.hpp"
#include "core/Minimize.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <string_view>
#include <vector>

using namespace gf::minimize;

namespace {
    constexpr double NaN = std::numeric_limits<double>::quiet_NaN();
    constexpr double EPS = 1e-6;

    // GF-REF (1920x1080 at (1440,0) in the nested layout): a 702x530 foot window and its Dock tile at the bottom.
    constexpr Box MONITOR{1440, 0, 1920, 1080};
    constexpr Box WINDOW{2050, 236, 702, 530};
    constexpr Box TILE{2300, 1010, 52, 52};

    constexpr std::array<Edge, 4> EDGES = {Edge::Bottom, Edge::Top, Edge::Left, Edge::Right};

    // A tile on each edge of MONITOR, and a window that is not touching it.
    Box tileOn(Edge edge) {
        switch (edge) {
            case Edge::Bottom: return {2300, 1010, 52, 52};
            case Edge::Top: return {2300, 40, 52, 52};
            case Edge::Left: return {1458, 500, 52, 52};
            case Edge::Right: return {3290, 500, 52, 52};
        }
        return {};
    }

    const char* name(Edge edge) {
        switch (edge) {
            case Edge::Bottom: return "bottom";
            case Edge::Top: return "top";
            case Edge::Left: return "left";
            case Edge::Right: return "right";
        }
        return "?";
    }

    Box unionBox(const Box& a, const Box& b) {
        const double x0 = std::min(a.x, b.x), y0 = std::min(a.y, b.y);
        const double x1 = std::max(a.x + a.w, b.x + b.w), y1 = std::max(a.y + a.h, b.y + b.h);
        return {x0, y0, x1 - x0, y1 - y0};
    }

    // Coordinate along the Dock axis, increasing toward the Dock edge.
    double along(const Point& p, Edge edge) {
        switch (edge) {
            case Edge::Bottom: return p.y;
            case Edge::Top: return -p.y;
            case Edge::Right: return p.x;
            case Edge::Left: return -p.x;
        }
        return 0;
    }

    double across(const Point& p, Edge edge) {
        return edge == Edge::Bottom || edge == Edge::Top ? p.x : p.y;
    }

    // Source fractions of the point at fractions (alpha across, beta along toward the Dock) of the window.
    Point sourceFractions(double alpha, double beta, Edge edge) {
        switch (edge) {
            case Edge::Bottom: return {alpha, beta};
            case Edge::Top: return {alpha, 1.0 - beta};
            case Edge::Right: return {beta, alpha};
            case Edge::Left: return {1.0 - beta, alpha};
        }
        return {};
    }
} // namespace

TEST(GenieEdge, TheDockEdgeIsTheMonitorSideClosestToTheTile) {
    EXPECT_EQ(dockEdge(TILE, MONITOR), Edge::Bottom);
    for (const Edge e : EDGES)
        EXPECT_EQ(dockEdge(tileOn(e), MONITOR), e) << name(e);
    // Ties: bottom first, then left.
    EXPECT_EQ(dockEdge({45, 45, 10, 10}, {0, 0, 100, 100}), Edge::Bottom);
    EXPECT_EQ(dockEdge({45, 95, 10, 10}, {0, 0, 100, 200}), Edge::Left);
    EXPECT_EQ(dockEdge({0, 0, 10, 10}, {0, 0, 10, 10}), Edge::Bottom);
    EXPECT_EQ(dockEdge({NaN, 0, 10, 10}, MONITOR), Edge::Bottom);
    EXPECT_EQ(dockEdge(TILE, {0, 0, 0, 0}), Edge::Bottom);
}

TEST(GenieGeometry, StartsExactlyAtTheWindow) {
    for (const Edge e : EDGES) {
        const Box    target = fitInside(WINDOW, tileOn(e));
        const CGenie g{WINDOW, target, e};
        for (int i = 0; i <= 10; ++i) {
            for (int j = 0; j <= 10; ++j) {
                const double u = i / 10.0, v = j / 10.0;
                const Point  p = g.at(u, v, 0.0);
                EXPECT_NEAR(p.x, WINDOW.x + (u * WINDOW.w), EPS) << name(e) << " u=" << u << " v=" << v;
                EXPECT_NEAR(p.y, WINDOW.y + (v * WINDOW.h), EPS) << name(e) << " u=" << u << " v=" << v;
            }
        }
    }
}

TEST(GenieGeometry, EndsExactlyInTheTarget) {
    for (const Edge e : EDGES) {
        const Box    target = fitInside(WINDOW, tileOn(e));
        const CGenie g{WINDOW, target, e};
        for (int i = 0; i <= 10; ++i) {
            for (int j = 0; j <= 10; ++j) {
                const double u = i / 10.0, v = j / 10.0;
                const Point  p = g.at(u, v, 1.0);
                // Same orientation as the window (no mirror): top-left of the window ends at the top-left of the target.
                EXPECT_NEAR(p.x, target.x + (u * target.w), EPS) << name(e) << " u=" << u << " v=" << v;
                EXPECT_NEAR(p.y, target.y + (v * target.h), EPS) << name(e) << " u=" << u << " v=" << v;
            }
        }
        // Progress is clamped: beyond the ends nothing moves further.
        const Point over = g.at(0.5, 0.5, 2.0), end = g.at(0.5, 0.5, 1.0);
        EXPECT_NEAR(over.x, end.x, EPS);
        EXPECT_NEAR(over.y, end.y, EPS);
        const Point under = g.at(0.5, 0.5, -1.0);
        EXPECT_NEAR(under.y, WINDOW.y + (0.5 * WINDOW.h), EPS);
    }
}

TEST(GenieGeometry, StaysInsideTheBoundsOfWindowAndTarget) {
    for (const Edge e : EDGES) {
        const Box    target = fitInside(WINDOW, tileOn(e));
        const Box    all    = unionBox(WINDOW, target);
        const CGenie g{WINDOW, target, e};
        for (int k = 0; k <= 100; ++k) {
            const double progress = k / 100.0;
            for (int i = 0; i <= 16; ++i) {
                for (int j = 0; j <= 16; ++j) {
                    const Point p = g.at(i / 16.0, j / 16.0, progress);
                    ASSERT_GE(p.x, all.x - EPS) << name(e) << " progress " << progress;
                    ASSERT_LE(p.x, all.x + all.w + EPS) << name(e) << " progress " << progress;
                    ASSERT_GE(p.y, all.y - EPS) << name(e) << " progress " << progress;
                    ASSERT_LE(p.y, all.y + all.h + EPS) << name(e) << " progress " << progress;
                }
            }
        }
    }
}

TEST(GenieGeometry, EveryPointMovesMonotonicallyTowardItsPlaceInTheTarget) {
    for (const Edge e : EDGES) {
        const Box    target = fitInside(WINDOW, tileOn(e));
        const CGenie g{WINDOW, target, e};
        for (int i = 0; i <= 8; ++i) {
            for (int j = 0; j <= 8; ++j) {
                const double u = i / 8.0, v = j / 8.0;
                const Point  end = g.at(u, v, 1.0);
                Point        previous = g.at(u, v, 0.0);
                for (int k = 1; k <= 200; ++k) {
                    const Point p = g.at(u, v, k / 200.0);
                    // Along the Dock axis: never back away from the Dock.
                    ASSERT_GE(along(p, e), along(previous, e) - EPS) << name(e) << " u=" << u << " v=" << v << " step " << k;
                    // Across: never further from where it ends.
                    ASSERT_LE(std::abs(across(p, e) - across(end, e)), std::abs(across(previous, e) - across(end, e)) + EPS)
                        << name(e) << " u=" << u << " v=" << v << " step " << k;
                    previous = p;
                }
            }
        }
    }
}

TEST(GenieGeometry, RowsNeverCrossAndSpansNeverInvert) {
    for (const Edge e : EDGES) {
        const Box    target = fitInside(WINDOW, tileOn(e));
        const CGenie g{WINDOW, target, e};
        for (int k = 0; k <= 100; ++k) {
            const double progress = k / 100.0;
            double       previousAlong = -std::numeric_limits<double>::infinity();
            for (int j = 0; j <= 64; ++j) {
                const double beta  = j / 64.0;
                const auto   lo    = sourceFractions(0.0, beta, e);
                const auto   hi    = sourceFractions(1.0, beta, e);
                const Point  first = g.at(lo.x, lo.y, progress);
                const Point  last  = g.at(hi.x, hi.y, progress);
                // A row is a straight segment across the Dock axis, at one depth.
                ASSERT_NEAR(along(first, e), along(last, e), EPS);
                ASSERT_GT(across(last, e) - across(first, e), 0.0) << name(e) << " progress " << progress << " beta " << beta;
                ASSERT_GT(along(first, e), previousAlong) << name(e) << " progress " << progress << " beta " << beta;
                previousAlong = along(first, e);
            }
        }
    }
}

TEST(GenieGeometry, MidwayTheShapeIsAGenieNotAScale) {
    // Half way the window's top keeps most of its width while its bottom is pinched to the tile's width: a uniform
    // scale (the Scale effect) would have one width for every row.
    const Box    target = fitInside(WINDOW, TILE);
    const CGenie g{WINDOW, target, Edge::Bottom};
    const auto   width  = [&](double v, double progress) { return g.at(1.0, v, progress).x - g.at(0.0, v, progress).x; };
    const double top    = width(0.0, 0.5);
    const double middle = width(0.5, 0.5);
    const double bottom = width(1.0, 0.5);
    EXPECT_GT(top, 0.8 * WINDOW.w);
    EXPECT_NEAR(bottom, target.w, 1.0);
    EXPECT_LT(bottom, top / 5);
    EXPECT_LT(middle, top);
    EXPECT_GT(middle, bottom);
    // The sides are curved (S-shaped funnel), not straight lines from the top corners to the tile.
    const double linearMiddle = (top + bottom) / 2;
    EXPECT_GT(std::abs(middle - linearMiddle), 10.0);
    // The bottom has reached the tile's bottom; the top has not moved much yet.
    EXPECT_NEAR(g.at(0.5, 1.0, 0.5).y, target.y + target.h, EPS);
    EXPECT_LT(g.at(0.5, 0.0, 0.5).y, WINDOW.y + 100);
    // The pinch comes first: early on the bottom is already narrower than the top while the top has not moved.
    EXPECT_LT(width(1.0, 0.2), 0.8 * width(0.0, 0.2));
    EXPECT_NEAR(g.at(0.5, 0.0, 0.2).y, WINDOW.y, EPS);
}

TEST(GenieGeometry, OnlyTowardTheDock) {
    EXPECT_TRUE(isGenieGeometry(WINDOW, fitInside(WINDOW, TILE), Edge::Bottom));
    for (const Edge e : EDGES)
        EXPECT_TRUE(isGenieGeometry(WINDOW, fitInside(WINDOW, tileOn(e)), e)) << name(e);
    // A window lying on the Dock still bends into it (the tile's bottom is beyond the window's top).
    EXPECT_TRUE(isGenieGeometry({2050, 700, 702, 370}, fitInside(WINDOW, TILE), Edge::Bottom));
    // A tile behind the window's far edge (above it with the Dock at the bottom): rows would cross, no genie.
    EXPECT_FALSE(isGenieGeometry(WINDOW, {2300, 100, 52, 52}, Edge::Bottom));
    EXPECT_FALSE(isGenieGeometry(WINDOW, {2300, 900, 52, 52}, Edge::Top));
    EXPECT_FALSE(isGenieGeometry(WINDOW, {1500, 500, 52, 52}, Edge::Right));
    EXPECT_FALSE(isGenieGeometry(WINDOW, {3000, 500, 52, 52}, Edge::Left));
    EXPECT_FALSE(isGenieGeometry({0, 0, 0, 10}, TILE, Edge::Bottom));
    EXPECT_FALSE(isGenieGeometry(WINDOW, {NaN, 1010, 52, 52}, Edge::Bottom));
}

TEST(GenieMesh, CoversTheRegionAtTheStartAndTheTargetAtTheEnd) {
    const Box                target = fitInside(WINDOW, TILE);
    const CGenie             g{WINDOW, target, Edge::Bottom};
    std::vector<SMeshVertex> mesh;
    genieMesh(g, WINDOW, WINDOW, 0.0, kGenieAcross, kGenieAlong, mesh);
    ASSERT_EQ(mesh.size(), static_cast<size_t>(meshVertexCount(kGenieAcross, kGenieAlong)));
    const Box start = meshBounds(mesh);
    EXPECT_NEAR(start.x, WINDOW.x, EPS);
    EXPECT_NEAR(start.y, WINDOW.y, EPS);
    EXPECT_NEAR(start.w, WINDOW.w, EPS);
    EXPECT_NEAR(start.h, WINDOW.h, EPS);
    // First vertex: the window's top-left corner, source fractions (0, 0); last: bottom-right, (1, 1).
    EXPECT_NEAR(mesh.front().u, 0.0, EPS);
    EXPECT_NEAR(mesh.front().v, 0.0, EPS);
    EXPECT_NEAR(mesh.back().u, 1.0, EPS);
    EXPECT_NEAR(mesh.back().v, 1.0, EPS);

    genieMesh(g, WINDOW, WINDOW, 1.0, kGenieAcross, kGenieAlong, mesh);
    const Box end = meshBounds(mesh);
    EXPECT_NEAR(end.x, target.x, EPS);
    EXPECT_NEAR(end.y, target.y, EPS);
    EXPECT_NEAR(end.w, target.w, EPS);
    EXPECT_NEAR(end.h, target.h, EPS);
}

TEST(GenieMesh, TheShadowAroundTheWindowIsExtrapolated) {
    const Box                shadow{WINDOW.x - 20, WINDOW.y - 20, WINDOW.w + 40, WINDOW.h + 40};
    const CGenie             g{WINDOW, fitInside(WINDOW, TILE), Edge::Bottom};
    std::vector<SMeshVertex> mesh;
    genieMesh(g, WINDOW, shadow, 0.0, kGenieAcross, kGenieAlong, mesh);
    const Box start = meshBounds(mesh);
    EXPECT_NEAR(start.x, shadow.x, EPS);
    EXPECT_NEAR(start.w, shadow.w, EPS);
    EXPECT_NEAR(mesh.front().u, -20.0 / WINDOW.w, EPS);
    EXPECT_NEAR(mesh.back().v, 1.0 + (20.0 / WINDOW.h), EPS);
    // Every edge orders its lines from the far edge to the near one, so one index buffer serves all.
    for (const Edge e : EDGES) {
        const CGenie ge{WINDOW, fitInside(WINDOW, tileOn(e)), e};
        genieMesh(ge, WINDOW, WINDOW, 0.5, kGenieAcross, kGenieAlong, mesh);
        ASSERT_EQ(mesh.size(), static_cast<size_t>(meshVertexCount(kGenieAcross, kGenieAlong)));
        EXPECT_LT(along({mesh.front().x, mesh.front().y}, e), along({mesh.back().x, mesh.back().y}, e)) << name(e);
    }
    genieMesh(g, WINDOW, {0, 0, 0, 0}, 0.5, kGenieAcross, kGenieAlong, mesh);
    EXPECT_TRUE(mesh.empty());
}

TEST(GenieMesh, IndicesAreTwoTrianglesPerQuadWithinRange) {
    const auto indices = meshIndices(kGenieAcross, kGenieAlong);
    ASSERT_EQ(indices.size(), static_cast<size_t>(kGenieAcross * kGenieAlong * 6));
    const auto max = *std::ranges::max_element(indices);
    EXPECT_EQ(max, meshVertexCount(kGenieAcross, kGenieAlong) - 1);
    const auto small = meshIndices(1, 1);
    EXPECT_EQ(small, (std::vector<uint16_t>{0, 2, 1, 1, 2, 3}));
    EXPECT_TRUE(meshIndices(0, 4).empty());
    EXPECT_TRUE(meshIndices(300, 300).empty()); // more than 16-bit indices can address
}

TEST(GenieTiming, MinimizeTakesHalfASecondAndFadesAtTheEnd) {
    EXPECT_DOUBLE_EQ(kGenieDurationMs, 500.0);
    const auto start = genieFrameAt(Kind::Minimize, 0);
    EXPECT_DOUBLE_EQ(start.progress, 0.0);
    EXPECT_FLOAT_EQ(start.alpha, 1.F);
    EXPECT_FALSE(start.done);
    const auto mid = genieFrameAt(Kind::Minimize, 250);
    EXPECT_DOUBLE_EQ(mid.progress, 0.5);
    EXPECT_FLOAT_EQ(mid.alpha, 1.F);
    EXPECT_NEAR(genieFrameAt(Kind::Minimize, 500 - (0.075 * 500)).alpha, 0.5F, 1e-5);
    const auto end = genieFrameAt(Kind::Minimize, 500);
    EXPECT_DOUBLE_EQ(end.progress, 1.0);
    EXPECT_FLOAT_EQ(end.alpha, 0.F);
    EXPECT_TRUE(end.done);
    EXPECT_TRUE(genieFrameAt(Kind::Minimize, NaN).done);
    EXPECT_FALSE(genieFrameAt(Kind::Minimize, -20).done);
}

TEST(GenieTiming, RestoreIsTheMinimizePlayedBackwards) {
    for (int ms = 0; ms <= 500; ms += 25) {
        EXPECT_NEAR(genieFrameAt(Kind::Restore, ms).progress, genieFrameAt(Kind::Minimize, 500 - ms).progress, 1e-12) << ms;
    }
    EXPECT_FLOAT_EQ(genieFrameAt(Kind::Restore, 0).alpha, 0.F);
    EXPECT_NEAR(genieFrameAt(Kind::Restore, 0.075 * 500).alpha, 0.5F, 1e-5);
    EXPECT_FLOAT_EQ(genieFrameAt(Kind::Restore, 250).alpha, 1.F);
    EXPECT_TRUE(genieFrameAt(Kind::Restore, 500).done);
}

TEST(GenieTiming, AnInterruptedAnimationContinuesFromTheShapeOnScreen) {
    for (const double progress : {0.0, 0.3, 0.75, 1.0}) {
        EXPECT_NEAR(genieFrameAt(Kind::Minimize, genieElapsedFor(Kind::Minimize, progress)).progress, progress, 1e-12);
        EXPECT_NEAR(genieFrameAt(Kind::Restore, genieElapsedFor(Kind::Restore, progress)).progress, progress, 1e-12);
    }
    EXPECT_DOUBLE_EQ(genieElapsedFor(Kind::Restore, 0.0), 500.0);
    EXPECT_DOUBLE_EQ(genieElapsedFor(Kind::Minimize, 2.0), 500.0);
}

TEST(MinimizeEffect, ConfigAllowlist) {
    EXPECT_EQ(kConfigMinimizeEffect, "minimizeEffect");
    // Grassfield's own value names (Settings dock.minimizeEffect); the internal enum keeps Genie / Scale.
    EXPECT_EQ(parseEffect("minimizeEffect", "funnel"), Effect::Genie);
    EXPECT_EQ(parseEffect("minimizeEffect", "shrink"), Effect::Scale);
    EXPECT_EQ(parseEffect("minimizeEffect", "fade"), Effect::Fade);
    EXPECT_FALSE(parseEffect("minimizeEffect", "genie")); // never a user-visible value
    EXPECT_FALSE(parseEffect("minimizeEffect", "scale"));
    EXPECT_FALSE(parseEffect("minimizeEffect", "Funnel"));
    EXPECT_FALSE(parseEffect("minimizeEffect", "funnel "));
    EXPECT_FALSE(parseEffect("minimizeEffect", ""));
    EXPECT_FALSE(parseEffect("minimizeEffect", std::string_view("shrink\0", 7)));
    EXPECT_FALSE(parseEffect("titlebarDoubleClick", "funnel"));
    EXPECT_FALSE(parseEffect("", "shrink"));
}

TEST(MinimizeEffect, FaultInjectionOnlyInADevSession) {
    EXPECT_TRUE(isFunnelShaderFault("testFault", "funnel-shader", true));
    EXPECT_FALSE(isFunnelShaderFault("testFault", "funnel-shader", false)); // the installed session never honours it
    EXPECT_FALSE(isFunnelShaderFault("testFault", "funnel", true));
    EXPECT_FALSE(isFunnelShaderFault("testFault", "funnel-shader ", true));
    EXPECT_FALSE(isFunnelShaderFault("minimizeEffect", "funnel-shader", true));
}

TEST(MinimizeEffect, ReduceMotionFadesInPlace) {
    EXPECT_DOUBLE_EQ(kFadeDurationMs, 100.0);
    const auto start = fadeFrameAt(Kind::Minimize, WINDOW, 0);
    EXPECT_EQ(start.box, WINDOW);
    EXPECT_FLOAT_EQ(start.alpha, 1.F);
    EXPECT_FALSE(start.done);
    const auto half = fadeFrameAt(Kind::Minimize, WINDOW, 50);
    EXPECT_EQ(half.box, WINDOW); // no movement
    EXPECT_NEAR(half.alpha, 0.5F, 1e-6);
    const auto end = fadeFrameAt(Kind::Minimize, WINDOW, 100);
    EXPECT_FLOAT_EQ(end.alpha, 0.F);
    EXPECT_TRUE(end.done);
    EXPECT_FLOAT_EQ(fadeFrameAt(Kind::Restore, WINDOW, 0).alpha, 0.F);
    EXPECT_NEAR(fadeFrameAt(Kind::Restore, WINDOW, 25).alpha, 0.25F, 1e-6);
    EXPECT_TRUE(fadeFrameAt(Kind::Restore, WINDOW, NaN).done);
}
