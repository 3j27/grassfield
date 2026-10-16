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

TEST(Protocol, OnlyImplementedFeaturesAreAdvertised) {
    // R11: minimize is a placeholder in this build and must not be advertised.
    EXPECT_EQ(capabilitiesJson().find("minimize"), std::string::npos);
}

TEST(Protocol, MinimizeRequestJson) {
    EXPECT_EQ(minimizeRequestJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"minimize-request","address":"55d3c2a0b1f0"})");
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
}

TEST(Protocol, LuaDispatchRequestIsWhatTheShellSends) {
    // Hyprland wraps it as `return hl.dispatch(hl.plugin.grassfield.hello())`.
    EXPECT_EQ(luaDispatchRequest(kLuaHello), "hl.plugin.grassfield.hello()");
}
