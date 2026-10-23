// Presented-frame timestamps (ADR-0006 gate P3, core/FrameLog.hpp): the ring keeps the last kCapacity frames in time order,
// the JSON `hyprctl grassfield-frames` returns, and the feature name.

#include "core/FrameLog.hpp"
#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

using namespace gf::frames;

TEST(FrameLog, KeepsFramesOldestFirst) {
    CRing ring;
    EXPECT_TRUE(ring.push(100));
    EXPECT_TRUE(ring.push(116));
    EXPECT_TRUE(ring.push(133));
    EXPECT_EQ(ring.snapshot(), (std::vector<uint64_t>{100, 116, 133}));
    EXPECT_EQ(ring.total(), 3U);
}

TEST(FrameLog, AFrameThatIsNotNewerIsRefused) {
    CRing ring;
    EXPECT_TRUE(ring.push(1000));
    EXPECT_FALSE(ring.push(1000)) << "a duplicate presentation event";
    EXPECT_FALSE(ring.push(999)) << "a clock that went backwards";
    EXPECT_EQ(ring.snapshot(), (std::vector<uint64_t>{1000}));
    EXPECT_EQ(ring.total(), 1U);
}

TEST(FrameLog, OnlyTheLastCapacityFramesAreKept) {
    CRing ring;
    for (uint64_t i = 1; i <= kCapacity + 10; ++i)
        ASSERT_TRUE(ring.push(i * 16667));
    const auto s = ring.snapshot();
    ASSERT_EQ(s.size(), kCapacity);
    EXPECT_EQ(s.front(), 11U * 16667) << "the 10 oldest were overwritten";
    EXPECT_EQ(s.back(), (kCapacity + 10) * 16667);
    EXPECT_EQ(ring.total(), kCapacity + 10);
    for (size_t i = 1; i < s.size(); ++i)
        ASSERT_LT(s[i - 1], s[i]) << "time order across the wrap";
}

TEST(FrameLog, JsonNamesTheClockAndEachMonitor) {
    const std::vector<MonitorFrames> m{{.name = "GF-REF", .refreshHz = 60, .total = 2, .presentedUs = {10, 26}},
                                       {.name = "WAYLAND-1", .refreshHz = 59.951, .total = 0, .presentedUs = {}}};
    EXPECT_EQ(framesJson(m), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)"
                             R"({"name":"GF-REF","refreshHz":60.000,"total":2,"presented":[10,26]},)"
                             R"({"name":"WAYLAND-1","refreshHz":59.951,"total":0,"presented":[]}]})");
    EXPECT_EQ(framesJson({}), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[]})");
}

TEST(FrameLog, JsonIsSafeWithOddMonitorData) {
    const std::vector<MonitorFrames> odd{{.name = "a\"b\\c\n", .refreshHz = std::nan(""), .total = 0, .presentedUs = {}}};
    EXPECT_EQ(framesJson(odd), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)"
                               R"({"name":"a\"b\\c\n","refreshHz":0.000,"total":0,"presented":[]}]})");
    // A long name is cut on a UTF-8 boundary: 63 ASCII bytes then a 2-byte character that would straddle byte 64.
    const std::string                longName = std::string(63, 'x') + "\xc3\xa9" + "tail";
    const std::vector<MonitorFrames> named{{.name = longName, .refreshHz = 60, .total = 0, .presentedUs = {}}};
    EXPECT_NE(framesJson(named).find("\"name\":\"" + std::string(63, 'x') + "\""), std::string::npos);
    std::vector<MonitorFrames> many(kMaxMonitors + 3, MonitorFrames{.name = "M", .refreshHz = 60, .total = 0, .presentedUs = {}});
    const auto                 json  = framesJson(many);
    size_t                     count = 0;
    for (size_t at = json.find("\"name\""); at != std::string::npos; at = json.find("\"name\"", at + 1))
        ++count;
    EXPECT_EQ(count, kMaxMonitors);
}

TEST(FrameLog, FeatureName) {
    using namespace gf::gfc;
    EXPECT_EQ(kFeatureFrameTimes, "frame-times");
    EXPECT_EQ(gf::frames::kHyprctlCommand, "grassfield-frames");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","frame-times"]})");
}
