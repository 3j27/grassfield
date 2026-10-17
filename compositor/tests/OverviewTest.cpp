#include "core/Minimize.hpp"
#include "core/Overview.hpp"

#include <gtest/gtest.h>

#include <format>
#include <string>

using namespace gf::overview;

namespace {
    void expectBox(const Box& actual, const Box& expected, double eps = 1e-9) {
        EXPECT_NEAR(actual.x, expected.x, eps);
        EXPECT_NEAR(actual.y, expected.y, eps);
        EXPECT_NEAR(actual.w, expected.w, eps);
        EXPECT_NEAR(actual.h, expected.h, eps);
    }

    std::string window(std::string_view address, double x, double y, double w, double h) {
        return std::format(R"({{"address":"{}","x":{},"y":{},"w":{},"h":{}}})", address, x, y, w, h);
    }

    // An error message, or "" when the payload parses.
    std::string errorOf(std::string_view json) {
        const auto r = parseRequest(json);
        return r ? std::string{} : r.error();
    }
} // namespace

TEST(OverviewRequest, ParsesTheShellPayload) {
    const auto r = parseRequest(R"({"on":true,"durationMs":350,"windows":[{"address":"0x55d0c0a1b2c0","x":1500,"y":120,"w":560,"h":400},)"
                                R"({"address":"55d0c0a1b3f0","x":2100.5,"y":120,"w":560,"h":400}]})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_TRUE(r->on);
    EXPECT_EQ(r->durationMs, 350);
    EXPECT_EQ(r->curve, Curve{});
    ASSERT_EQ(r->windows.size(), 2U);
    EXPECT_EQ(r->windows[0].address, 0x55d0c0a1b2c0ULL);
    expectBox(r->windows[0].rect, {1500, 120, 560, 400});
    EXPECT_EQ(r->windows[1].address, 0x55d0c0a1b3f0ULL);
    expectBox(r->windows[1].rect, {2100.5, 120, 560, 400});
}

TEST(OverviewRequest, OffNeedsNoWindows) {
    const auto r = parseRequest(R"({"on":false,"durationMs":0})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_FALSE(r->on);
    EXPECT_EQ(r->durationMs, 0);
    EXPECT_TRUE(r->windows.empty());
}

TEST(OverviewRequest, EmptyWindowListIsValid) {
    const auto r = parseRequest(R"( { "on" : true , "durationMs" : 0 , "windows" : [ ] } )");
    ASSERT_TRUE(r) << r.error();
    EXPECT_TRUE(r->windows.empty());
}

TEST(OverviewRequest, CurveIsOptionalAndValidated) {
    const auto r = parseRequest(R"({"on":false,"durationMs":300,"curve":[0.4,0,1,1]})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->curve, (Curve{0.4, 0, 1, 1}));
    EXPECT_TRUE(parseRequest(R"({"on":false,"durationMs":300,"curve":[0.3,-1,0.2,2]})")); // overshoot allowed
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":[1.2,0,1,1]})"), "");      // x out of [0, 1]
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":[0.2,0,-0.1,1]})"), "");
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":[0.2,-1.5,0,1]})"), ""); // y out of range
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":[0.2,0,0]})"), "");      // 3 numbers
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":[0.2,0,0,1,1]})"), "");  // 5 numbers
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300,"curve":"ease"})"), "");
}

TEST(OverviewRequest, UnknownKeysAreSkipped) {
    const auto r = parseRequest(R"({"future":{"a":[1,2,{"b":null}],"c":"x\"y"},"on":true,"durationMs":10,"windows":[)"
                                R"({"address":"0x1f","x":0,"y":0,"w":10,"h":10,"title":"ignored","n":-1.5e3,"t":true}],"z":false})");
    ASSERT_TRUE(r) << r.error();
    ASSERT_EQ(r->windows.size(), 1U);
    EXPECT_EQ(r->windows[0].address, 0x1fULL);
}

TEST(OverviewRequest, RequiredFields) {
    EXPECT_NE(errorOf(R"({"durationMs":0})"), "");
    EXPECT_NE(errorOf(R"({"on":false})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0})"), ""); // windows required when on
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":0,"y":0,"w":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"x":0,"y":0,"w":10,"h":10}]})"), "");
}

TEST(OverviewRequest, TypesAreStrict) {
    EXPECT_NE(errorOf(R"({"on":1,"durationMs":0})"), "");
    EXPECT_NE(errorOf(R"({"on":"true","durationMs":0})"), "");
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":"300"})"), "");
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":300.5})"), ""); // integer
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":-1})"), "");
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":2001})"), "");
    EXPECT_EQ(errorOf(R"({"on":false,"durationMs":2000})"), "");
    EXPECT_EQ(errorOf(R"({"on":false,"durationMs":3e2})"), ""); // an integer written with an exponent
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":{}})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[1]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":12,"x":0,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":"0","y":0,"w":10,"h":10}]})"), "");
}

TEST(OverviewRequest, NumbersMustBeFinite) {
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":1e999,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":NaN,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":Infinity,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":0x10,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":01,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":1.,"y":0,"w":10,"h":10}]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":+1,"y":0,"w":10,"h":10}]})"), "");
}

TEST(OverviewRequest, SizesAtLeastOnePixel) {
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x1", 0, 0, 0.5, 10) + "]}"), "");
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x1", 0, 0, 10, -10) + "]}"), "");
    EXPECT_EQ(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x1", -5, -5, 1, 1) + "]}"), ""); // bounds: glue
}

TEST(OverviewRequest, Addresses) {
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x", 0, 0, 10, 10) + "]}"), "");
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x0", 0, 0, 10, 10) + "]}"), "");
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0xnothex", 0, 0, 10, 10) + "]}"), "");
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0x11111111111111111", 0, 0, 10, 10) + "]}"), "");
    // The same window twice is a shell bug: refused.
    EXPECT_NE(errorOf("{\"on\":true,\"durationMs\":0,\"windows\":[" + window("0xab", 0, 0, 10, 10) + "," + window("0xAB", 20, 0, 10, 10) + "]}"), "");
}

TEST(OverviewRequest, AtMost64Windows) {
    auto build = [](size_t n) {
        std::string json = R"({"on":true,"durationMs":0,"windows":[)";
        for (size_t i = 0; i < n; ++i) {
            if (i > 0)
                json += ',';
            json += window(std::format("0x{:x}", i + 1), static_cast<double>(i), 0, 10, 10);
        }
        return json + "]}";
    };
    const auto ok = parseRequest(build(kMaxWindows));
    ASSERT_TRUE(ok) << ok.error();
    EXPECT_EQ(ok->windows.size(), kMaxWindows);
    EXPECT_NE(errorOf(build(kMaxWindows + 1)), "");
}

TEST(OverviewRequest, PayloadSizeLimit) {
    std::string json = R"({"on":false,"durationMs":0,"pad":")";
    json += std::string(kMaxPayloadBytes, 'a');
    json += "\"}";
    EXPECT_NE(errorOf(json), "");
}

TEST(OverviewRequest, MalformedJson) {
    for (const char* bad : {"", "null", "[]", "{", "}", R"({"on":false,"durationMs":0)", R"({"on":false,"durationMs":0}})", R"({"on":false,"durationMs":0} x)",
                            R"({"on":false,,"durationMs":0})", R"({"on":false,"durationMs":0,})", R"({on:false,"durationMs":0})", R"({'on':false,"durationMs":0})",
                            R"({"on":false "durationMs":0})", R"({"on":fals,"durationMs":0})", R"({"on":false,"durationMs":0,"x":"unterminated})",
                            R"({"on":false,"durationMs":0,"x":"bad \q escape"})", R"({"on":false,"durationMs":0,"x":"\ud800"})",
                            R"({"on":false,"durationMs":0,"x":"\udc00"})", "{\"on\":false,\"durationMs\":0,\"x\":\"raw\ttab\"}"}) {
        EXPECT_NE(errorOf(bad), "") << bad;
    }
}

TEST(OverviewRequest, EscapesInKeysAndStrings) {
    // "on" spelled with an escape is still the key "on"; a valid surrogate pair is accepted in a skipped value.
    const auto r = parseRequest(R"({"on":true,"durationMs":0,"windows":[],"emoji":"😀 é \/"})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_TRUE(r->on);
}

TEST(OverviewRequest, DuplicateKeysAreRefused) {
    EXPECT_NE(errorOf(R"({"on":true,"on":false,"durationMs":0})"), "");
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":0,"durationMs":1})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[],"windows":[]})"), "");
    EXPECT_NE(errorOf(R"({"on":true,"durationMs":0,"windows":[{"address":"0x1","x":0,"x":1,"y":0,"w":10,"h":10}]})"), "");
}

TEST(OverviewRequest, DeepNestingIsRefused) {
    std::string deep(40, '[');
    deep += std::string(40, ']');
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":0,"x":)" + deep + "}"), "");
    std::string ok(10, '[');
    ok += std::string(10, ']');
    EXPECT_EQ(errorOf(R"({"on":false,"durationMs":0,"x":)" + ok + "}"), "");
}

TEST(OverviewRequest, LongStringsAreRefused) {
    EXPECT_NE(errorOf(R"({"on":false,"durationMs":0,"x":")" + std::string(kMaxStringBytes + 1, 'a') + "\"}"), "");
    EXPECT_EQ(errorOf(R"({"on":false,"durationMs":0,"x":")" + std::string(kMaxStringBytes, 'a') + "\"}"), "");
}

TEST(OverviewBounds, InsideMonitor) {
    const Box mon{1440, 0, 1920, 1080};
    EXPECT_TRUE(insideMonitor({1440, 0, 1920, 1080}, mon));
    EXPECT_TRUE(insideMonitor({1439.5, -0.5, 100, 100}, mon)); // 1 px tolerance
    EXPECT_FALSE(insideMonitor({1400, 0, 100, 100}, mon));
    EXPECT_FALSE(insideMonitor({3000, 1000, 400, 100}, mon));
    EXPECT_FALSE(insideMonitor({1500, 0, 0, 100}, mon));
    EXPECT_FALSE(insideMonitor({1500, 0, 100, 100}, {0, 0, 0, 0}));
}

TEST(OverviewTiming, ProgressClampsAndHandlesZeroDuration) {
    EXPECT_EQ(progress(0, 350), 0.0);
    EXPECT_DOUBLE_EQ(progress(175, 350), 0.5);
    EXPECT_EQ(progress(400, 350), 1.0);
    EXPECT_EQ(progress(-10, 350), 0.0);
    EXPECT_EQ(progress(0, 0), 1.0); // no animation
    EXPECT_EQ(progress(1e300 * 1e300, 350), 1.0);
}

TEST(OverviewTiming, DefaultCurveIsTheShellsStandardCurve) {
    const Curve c{};
    EXPECT_EQ(eased(c, 0.0), 0.0);
    EXPECT_EQ(eased(c, 1.0), 1.0);
    // cubic-bezier(0.2, 0, 0, 1): decelerating, well past half way at half time, monotonic.
    EXPECT_GT(eased(c, 0.5), 0.8);
    double last = 0;
    for (int i = 1; i <= 100; ++i) {
        const double v = eased(c, i / 100.0);
        EXPECT_GE(v, last);
        last = v;
    }
}

TEST(OverviewGeometry, DrawBoxKeepsTheAspectRatioAndCenters) {
    // A 700x500 window into a 350x300 rect: scale 0.5, centered vertically.
    expectBox(drawBox({100, 100, 700, 500}, {1000, 200, 350, 300}), {1000, 225, 350, 250});
    // Exactly proportional: the rect itself.
    expectBox(drawBox({0, 0, 800, 600}, {10, 20, 400, 300}), {10, 20, 400, 300});
}

TEST(OverviewGeometry, InterpolationBetweenLiveAndFixedBoxes) {
    const Box live{100, 100, 700, 500};
    const Box target{1000, 200, 350, 250};
    // Opening: from the live box to the target.
    expectBox(interpolate(std::nullopt, target, live, 0.0), live);
    expectBox(interpolate(std::nullopt, target, live, 1.0), target);
    expectBox(interpolate(std::nullopt, target, live, 0.5), {550, 150, 525, 375});
    // Closing: from where it was drawn back to the live box (which may have moved meanwhile).
    const Box moved{120, 100, 700, 500};
    expectBox(interpolate(target, std::nullopt, moved, 1.0), moved);
    // Retarget: fixed to fixed.
    expectBox(interpolate(Box{0, 0, 10, 10}, Box{10, 10, 20, 20}, live, 0.5), {5, 5, 15, 15});
}

TEST(OverviewGeometry, TextureBoxPutsTheSurfaceOnItsTarget) {
    // GF-REF at (1440,0), scale 1, 1920x1080: a window at (1600,200) 700x500 drawn at (1500,100) 350x250 means the
    // whole monitor-sized buffer is drawn at half size, offset so that the window's pixels land on the target.
    const gf::minimize::SSnapshotGeometry g{.visible = {1600, 200, 700, 500}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1, .texW = 1920, .texH = 1080};
    const Box                             tex = gf::minimize::textureBox(g, {1500, 100, 350, 250}, 1440, 0, 1);
    expectBox(tex, {60 - (160 * 0.5), 100 - (200 * 0.5), 960, 540});
    // Where the window's top-left pixel (160,200 in the buffer) lands: on the target's top-left (60,100 local).
    EXPECT_DOUBLE_EQ(tex.x + (160 * 0.5), 60);
    EXPECT_DOUBLE_EQ(tex.y + (200 * 0.5), 100);
    // Scale 2 monitor: same layout, pixel coordinates doubled.
    const gf::minimize::SSnapshotGeometry g2{.visible = {1600, 200, 700, 500}, .monitorX = 1440, .monitorY = 0, .monitorScale = 2, .texW = 3840, .texH = 2160};
    expectBox(gf::minimize::textureBox(g2, {1500, 100, 350, 250}, 1440, 0, 2), {2 * (60 - (160 * 0.5)), 2 * (100 - (200 * 0.5)), 1920, 1080});
}

TEST(OverviewEvents, Json) {
    EXPECT_EQ(eventJson(Phase::Opening, 6), R"({"v":"gfc/1","type":"overview","state":"opening","windows":6})");
    EXPECT_EQ(eventJson(Phase::Open, 6), R"({"v":"gfc/1","type":"overview","state":"open","windows":6})");
    EXPECT_EQ(eventJson(Phase::Closing, 6), R"({"v":"gfc/1","type":"overview","state":"closing","windows":6})");
    EXPECT_EQ(eventJson(Phase::Closed, 0), R"({"v":"gfc/1","type":"overview","state":"closed","windows":0})");
    EXPECT_EQ(eventJson(Phase::Closed, 0, Reason::Invalid), R"({"v":"gfc/1","type":"overview","state":"closed","windows":0,"reason":"invalid"})");
    EXPECT_EQ(eventJson(Phase::Open, 3, Reason::NoWindows), R"({"v":"gfc/1","type":"overview","state":"open","windows":3,"reason":"no-windows"})");
    EXPECT_EQ(eventJson(Phase::Closed, 0, Reason::Unavailable), R"({"v":"gfc/1","type":"overview","state":"closed","windows":0,"reason":"unavailable"})");
    EXPECT_EQ(eventJson(Phase::Closing, 2, Reason::Interrupted), R"({"v":"gfc/1","type":"overview","state":"closing","windows":2,"reason":"interrupted"})");
}
