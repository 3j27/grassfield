// Key paths log nothing (core/Quiet.hpp; review of part B, 2026-10-24): the scope itself, and a check of the plugin's sources
// that every listener of a key event opens it, so that nothing it calls, however deep, can write a line per key.

#include "core/Quiet.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using gf::quiet::CKeyPath;
using gf::quiet::inKeyPath;

TEST(Quiet, ScopesNest) {
    EXPECT_FALSE(inKeyPath());
    {
        const CKeyPath outer;
        EXPECT_TRUE(inKeyPath());
        {
            const CKeyPath inner;
            EXPECT_TRUE(inKeyPath());
        }
        EXPECT_TRUE(inKeyPath()) << "the outer scope is still open";
    }
    EXPECT_FALSE(inKeyPath());
}

TEST(Quiet, AScopeClosesWhenItsCodeThrows) {
    try {
        const CKeyPath scope;
        throw std::runtime_error("x");
    } catch (const std::runtime_error&) { // NOLINT(bugprone-empty-catch): the throw is the test
    }
    EXPECT_FALSE(inKeyPath());
}

// Coordinator, 2026-10-24 (stages.sh 60/66 after aedc242; counter-review m4): the wrapper gives the body the listener's
// own event and callback info and changes neither; the body's work stands; it only opens the scope. The types stand in for
// IKeyboard::SKeyEvent and Event::SCallbackInfo (their fields; no Hyprland header in the unit tests).
TEST(Quiet, AKeyListenerUnderTheScopeLetsTheEventThroughUnchanged) {
    struct SKeyEvent {
        uint32_t timeMs  = 1234;
        uint32_t keycode = 30;
        uint32_t state   = 1; // pressed
        bool     operator==(const SKeyEvent&) const = default;
    };
    struct SCallbackInfo {
        bool cancelled = false;
    };
    const SKeyEvent original;
    SKeyEvent       event = original;
    SCallbackInfo   info;
    int             calls  = 0;
    bool            inside = false;
    SKeyEvent       seen{.timeMs = 0, .keycode = 0, .state = 0};
    int             moved = 0; // a side effect of the body (as keepActiveOffStrip moves the focus)
    const auto      body  = [&](const SKeyEvent& e, SCallbackInfo& i) {
        ++calls;
        inside = inKeyPath();
        seen   = e;
        moved  = static_cast<int>(e.keycode);
        EXPECT_FALSE(i.cancelled);
    };
    EXPECT_TRUE(gf::quiet::runKeyPath(body, event, info));
    EXPECT_EQ(calls, 1) << "the body runs exactly once";
    EXPECT_TRUE(inside);
    EXPECT_EQ(seen, original) << "the body got the listener's own event";
    EXPECT_EQ(moved, 30) << "its work stands";
    EXPECT_EQ(event, original) << "the event is untouched";
    EXPECT_FALSE(info.cancelled) << "the cancel flag is untouched";
    EXPECT_FALSE(inKeyPath()) << "the scope is closed after it";
    EXPECT_FALSE(gf::quiet::runKeyPath([](const SKeyEvent&, SCallbackInfo&) { throw std::runtime_error("x"); }, event, info)) << "an exception stays here";
    EXPECT_FALSE(inKeyPath());
    EXPECT_EQ(event, original);
    EXPECT_FALSE(info.cancelled);
}

namespace {
    std::string slurp(const std::filesystem::path& p) {
        std::ifstream     in(p);
        std::stringstream ss;
        ss << in.rdbuf();
        return ss.str();
    }
} // namespace

// Every `keyboard.key.listen(` of the plugin runs its body through gf::keyPath (Plugin.hpp), which opens the scope. A new key
// listener without it fails here. No function hook on Hyprland's key handling either (it would bypass the bus listeners).
TEST(Quiet, EveryKeyListenerOfThePluginOpensTheScope) {
    const std::filesystem::path dir{GF_PLUGIN_SOURCE_DIR};
    ASSERT_TRUE(std::filesystem::is_directory(dir)) << dir;
    std::vector<std::string> missing;
    int                      listeners = 0;
    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (entry.path().extension() != ".cpp")
            continue;
        const std::string text = slurp(entry.path());
        EXPECT_EQ(text.find("onKeyboardKey"), std::string::npos) << entry.path().filename() << " hooks Hyprland's key handler";
        for (size_t at = text.find("keyboard.key.listen("); at != std::string::npos; at = text.find("keyboard.key.listen(", at + 1)) {
            ++listeners;
            const size_t end  = text.find("}));", at);
            const auto   body = text.substr(at, end == std::string::npos ? std::string::npos : end - at);
            if (body.find("keyPath(") == std::string::npos)
                missing.push_back(entry.path().filename().string() + " at byte " + std::to_string(at));
        }
    }
    EXPECT_GE(listeners, 3) << "the titlebar, Overview focus and Stages key listeners";
    EXPECT_TRUE(missing.empty()) << "key listeners without gf::keyPath: " << ::testing::PrintToString(missing);
}
