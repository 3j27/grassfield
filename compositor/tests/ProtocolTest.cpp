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
    // R11: minimize and config are advertised only when their entry points registered at load.
    EXPECT_EQ(capabilitiesJson().find("minimize"), std::string::npos);
    EXPECT_EQ(capabilitiesJson(features(false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
    EXPECT_EQ(capabilitiesJson(features(true, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]})");
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
    EXPECT_EQ(kFeatureMinimize, "minimize");
    EXPECT_EQ(kFeatureConfig, "config");
    EXPECT_EQ(kConfigTitlebarDoubleClick, "titlebarDoubleClick");
}

TEST(Protocol, LuaDispatchRequestIsWhatTheShellSends) {
    // Hyprland wraps it as `return hl.dispatch(hl.plugin.grassfield.hello())`.
    EXPECT_EQ(luaDispatchRequest(kLuaHello), "hl.plugin.grassfield.hello()");
}
