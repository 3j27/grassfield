#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <string>
#include <string_view>

using namespace gf::gfc;

TEST(Protocol, CapabilitiesJsonIsExactWireFormat) {
    EXPECT_EQ(capabilitiesJson(), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
}

TEST(Protocol, Socket2LineMatchesWhatSubscribersReceive) {
    EXPECT_EQ(socket2Line(capabilitiesJson()), R"(grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]})");
}

TEST(Protocol, CapabilitiesWithNoFeatures) {
    EXPECT_EQ(capabilitiesJson({}), R"({"v":"gfc/1","type":"capabilities","features":[]})");
}

TEST(Protocol, CapabilitiesWithSeveralFeaturesKeepsOrder) {
    constexpr std::string_view features[] = {"decorations", "minimize"};
    EXPECT_EQ(capabilitiesJson(features), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize"]})");
}

TEST(Protocol, OnlyRegisteredFeaturesAreAdvertised) {
    // R11: minimize, config and appmenu are advertised only when their entry points registered at load.
    EXPECT_EQ(capabilitiesJson().find("minimize"), std::string::npos);
    EXPECT_EQ(capabilitiesJson(features(false, false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
    EXPECT_EQ(capabilitiesJson(features(true, false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","appmenu"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","overview"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","desktop-focus","desktop-focus-v2"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2"]})");
}

// Stages (ADR-0013): the toggle needs "stages-available"; "stages" follows the feature flag and never comes alone.
TEST(Protocol, StagesFeaturesFollowAvailabilityAndTheFlag) {
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, true, false)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","stages-available"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","stages-available","stages"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "flag on but the hooks failed: nothing advertised";
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","stages"]})");
    EXPECT_EQ(luaDispatchRequest(kLuaStages), "hl.plugin.grassfield.stages()");
}

TEST(Protocol, WithdrawnCapabilitiesHaveNoFeature) {
    // Posted at unload: the shell drops every feature (desktop-focus included) and uses its fallbacks.
    EXPECT_EQ(capabilitiesJson({}), R"({"v":"gfc/1","type":"capabilities","features":[]})");
}

TEST(Protocol, AppmenuJsonIsExactWireFormat) {
    EXPECT_EQ(appmenuJson("55d3c2a0b1f0", ":1.42", "/MenuBar/1", 4242),
              R"({"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":":1.42","path":"/MenuBar/1","pid":4242})");
    EXPECT_EQ(socket2Line(appmenuJson("55d3c2a0b1f0", "org.kde.Foo", "/a/b", 7)),
              R"(grassfield>>{"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":"org.kde.Foo","path":"/a/b","pid":7})");
}

TEST(Protocol, AppmenuClearHasEmptyServiceAndPath) {
    EXPECT_EQ(appmenuJson("55d3c2a0b1f0", "", "", 0), R"({"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":"","path":"","pid":0})");
}

TEST(Protocol, AppmenuPidIsANonNegativeInteger) {
    // pid is additive within gfc/1 (consumers that ignore it keep working); unknown or invalid pids are 0.
    EXPECT_EQ(appmenuJson("1", ":1.2", "/m", -1), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.2","path":"/m","pid":0})");
    EXPECT_EQ(appmenuJson("1", ":1.2", "/m", 2147483647), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.2","path":"/m","pid":2147483647})");
}

TEST(Protocol, AppmenuJsonEscapesEveryField) {
    // Validation rejects these strings before they reach the JSON; the JSON stays well-formed regardless.
    EXPECT_EQ(appmenuJson(R"(a"b)", R"(x","type":"evil)", "/p\n\\", 1),
              R"({"v":"gfc/1","type":"appmenu","address":"a\"b","service":"x\",\"type\":\"evil","path":"/p\n\\","pid":1})");
    EXPECT_EQ(appmenuJson("1", std::string_view(":1.\0", 4), "/\x01", 0), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.\u0000","path":"/\u0001","pid":0})");
}

TEST(Protocol, MinimizeRequestJson) {
    EXPECT_EQ(minimizeRequestJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"minimize-request","address":"55d3c2a0b1f0"})");
}

TEST(Protocol, MinimizedAndRestoredEvents) {
    EXPECT_EQ(minimizedJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"minimized","address":"55d3c2a0b1f0"})");
    EXPECT_EQ(restoredJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"restored","address":"55d3c2a0b1f0"})");
    EXPECT_EQ(restoredJson(R"(x"})"), R"({"v":"gfc/1","type":"restored","address":"x\"}"})");
}

TEST(Protocol, ConfigAllowlist) {
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "zoom"), DoubleClickAction::Zoom);
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "minimize"), DoubleClickAction::Minimize);
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "none"), DoubleClickAction::None);
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", "Zoom"));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", "zoom "));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", ""));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", std::string_view("zoom\0", 5)));
    EXPECT_FALSE(parseDoubleClickAction("appearance", "zoom"));
    EXPECT_FALSE(parseDoubleClickAction("", "zoom"));
}

TEST(Protocol, JsonEscapeQuotesBackslashAndControls) {
    EXPECT_EQ(jsonEscape(R"(a"b\c)"), R"(a\"b\\c)");
    EXPECT_EQ(jsonEscape("line\nnext\ttab\r\b\f"), R"(line\nnext\ttab\r\b\f)");
    EXPECT_EQ(jsonEscape(std::string_view("\x01\x1f", 2)), R"(\u0001\u001f)");
    EXPECT_EQ(jsonEscape(std::string_view("nul\0x", 5)), R"(nul\u0000x)");
}

TEST(Protocol, JsonEscapeKeepsUtf8) {
    EXPECT_EQ(jsonEscape("Fenêtre — 窓"), "Fenêtre — 窓");
}

TEST(Protocol, EscapedAddressCannotBreakTheObject) {
    EXPECT_EQ(minimizeRequestJson(R"(x","type":"evil)"), R"({"v":"gfc/1","type":"minimize-request","address":"x\",\"type\":\"evil"})");
}

TEST(Protocol, NamesAreStable) {
    EXPECT_EQ(kVersion, "gfc/1");
    EXPECT_EQ(kEventName, "grassfield");
    EXPECT_EQ(kHyprctlCommand, "grassfield");
    EXPECT_EQ(kLuaNamespace, "grassfield");
    EXPECT_EQ(kLuaHello, "hello");
    EXPECT_EQ(kLuaMinimize, "minimize");
    EXPECT_EQ(kLuaRestore, "restore");
    EXPECT_EQ(kLuaConfig, "config");
    EXPECT_EQ(kLuaAppmenu, "appmenu");
    EXPECT_EQ(kFeatureMinimize, "minimize");
    EXPECT_EQ(kFeatureConfig, "config");
    EXPECT_EQ(kFeatureAppmenu, "appmenu");
    EXPECT_EQ(kFeatureOverview, "overview");
    EXPECT_EQ(kFeatureDesktopFocus, "desktop-focus");
    EXPECT_EQ(kFeatureDesktopFocusV2, "desktop-focus-v2");
    EXPECT_EQ(kFeatureStagesAvailable, "stages-available");
    EXPECT_EQ(kFeatureStages, "stages");
    EXPECT_EQ(kLuaStages, "stages");
    EXPECT_EQ(kConfigTitlebarDoubleClick, "titlebarDoubleClick");
}

TEST(Protocol, LuaDispatchRequestIsWhatTheShellSends) {
    // Hyprland wraps it as `return hl.dispatch(hl.plugin.grassfield.hello())`.
    EXPECT_EQ(luaDispatchRequest(kLuaHello), "hl.plugin.grassfield.hello()");
}
