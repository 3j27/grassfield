// What a process is (apps/activity/src/units.cpp; ADR-0038 AD20, AD22, AD26; docs/specs/activity.md AM54, AM65, AM68,
// acceptance A-S4): uwsm's unit names and escapes, the session processes, the kinds, Efficiency Mode's eligibility.
#include "units.h"

#include <gtest/gtest.h>

using namespace activity;

namespace
{
const std::string user = "/user.slice/user-1000.slice/user@1000.service";
}

TEST(Units, UnescapeUndoesSystemdEscapes)
{
    EXPECT_EQ(unescapeUnit("grassfield\\x2dsettings"), "grassfield-settings");
    EXPECT_EQ(unescapeUnit("a\\x2fb"), "a/b");
    EXPECT_EQ(unescapeUnit("plain"), "plain");
    EXPECT_EQ(unescapeUnit("broken\\x2"), "broken\\x2");
    EXPECT_EQ(unescapeUnit("broken\\xzz"), "broken\\xzz");
}

TEST(Units, AppUnitByCommandWithEscapes)
{
    // uwsm-app -- grassfield-settings: the command's basename, "-" escaped (A7).
    const auto u = parseAppUnit("app-Hyprland-grassfield\\x2dsettings-1a2b3c4d.scope");
    ASSERT_TRUE(u.has_value());
    EXPECT_EQ(u->desktop, "Hyprland");
    EXPECT_EQ(u->name, "grassfield-settings");
    EXPECT_EQ(u->suffix, "1a2b3c4d");
    EXPECT_TRUE(u->scope);
}

TEST(Units, AppUnitByDesktopIdAndAsAService)
{
    // uwsm app -- org.mozilla.firefox.desktop: the desktop id without ".desktop" (main.py:3421), as a service.
    const auto u = parseAppUnit("app-Hyprland-org.mozilla.firefox@deadbeef.service");
    ASSERT_TRUE(u.has_value());
    EXPECT_EQ(u->name, "org.mozilla.firefox");
    EXPECT_FALSE(u->scope);
}

TEST(Units, NotAnAppUnit)
{
    EXPECT_FALSE(parseAppUnit("app-Hyprland-foot.scope").has_value());          // no random suffix
    EXPECT_FALSE(parseAppUnit("app-Hyprland-foot-1a2b3c4.scope").has_value());  // 7 digits
    EXPECT_FALSE(parseAppUnit("app-Hyprland-foot-1a2b3c4z.scope").has_value()); // not hex
    EXPECT_FALSE(parseAppUnit("pipewire.service").has_value());
    EXPECT_FALSE(parseAppUnit("app-Hyprland-a-b-1a2b3c4d.scope").has_value()); // an unescaped "-" in the name
    EXPECT_FALSE(parseAppUnit("app-x@1a2b3c4d.service").has_value());          // no desktop part
}

TEST(Units, SessionProcesses)
{
    // AM54: units of session.slice and session-graphical.slice (the compositor through wayland-wm@, the shell)...
    EXPECT_TRUE(isSessionProcess(user + "/session.slice/wayland-wm@hyprland.desktop.service"));
    EXPECT_TRUE(isSessionProcess(user + "/session.slice/grassfield-shell.service"));
    EXPECT_TRUE(isSessionProcess(user + "/session-graphical.slice/foo.service"));
    // ...uwsm's binding of the session to its login process, in background.slice (A7: its end ends the session)...
    EXPECT_TRUE(isSessionProcess(user + "/background.slice/wayland-session-bindpid@1234.service"));
    // ...the login session's scope and the user manager.
    EXPECT_TRUE(isSessionProcess("/user.slice/user-1000.slice/session-3.scope"));
    EXPECT_TRUE(isSessionProcess(user + "/init.scope"));
    // Not session processes.
    EXPECT_FALSE(isSessionProcess(user + "/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope"));
    EXPECT_FALSE(isSessionProcess(user + "/app.slice/pipewire.service"));
    EXPECT_FALSE(isSessionProcess(user + "/background.slice/other@1.service"));
    EXPECT_FALSE(isSessionProcess("/init.scope")); // PID 1 of the system: root's, a system process, not this user's session
    EXPECT_FALSE(isSessionProcess("/system.slice/session-3.scope"));
    EXPECT_FALSE(isSessionProcess(""));
}

TEST(Units, Kinds)
{
    const std::string app = user + "/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope";
    EXPECT_EQ(classify(app, true, false, false), Kind::App);
    EXPECT_EQ(classify(user + "/app.slice/app-graphical.slice/app-Hyprland-org.mozilla.firefox@deadbeef.service", true, false, false), Kind::App);
    EXPECT_EQ(classify(user + "/app.slice/pipewire.service", true, false, false), Kind::Background);
    EXPECT_EQ(classify(user + "/app.slice/pipewire.service", true, false, true), Kind::App); // owns a window (AM60)
    EXPECT_EQ(classify(user + "/background.slice/wayland-session-bindpid@1234.service", true, false, false), Kind::Session);
    EXPECT_EQ(classify("/user.slice/user-1000.slice/session-3.scope", true, false, true), Kind::Session); // session first
    EXPECT_EQ(classify(user + "/init.scope", true, false, false), Kind::Session);
    EXPECT_EQ(classify("/system.slice/systemd-journald.service", false, true, false), Kind::System);
    EXPECT_EQ(classify("/user.slice/user-1001.slice/session-4.scope", false, false, false), Kind::OtherUser);
}

TEST(Units, EfficiencyModeOnlyOnPerLaunchAppUnits)
{
    EXPECT_TRUE(efficiencyEligible(user + "/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope"));
    EXPECT_TRUE(efficiencyEligible(user + "/app.slice/app-graphical.slice/app-Hyprland-org.gnome.Calculator@0123abcd.service"));
    EXPECT_FALSE(efficiencyEligible(user + "/app.slice/pipewire.service")); // long-lived: its drop-in would outlive a restart
    EXPECT_FALSE(efficiencyEligible(user + "/app.slice/app-graphical.slice/some-unit.service"));
    EXPECT_FALSE(efficiencyEligible(user + "/session.slice/grassfield-shell.service"));
    EXPECT_FALSE(efficiencyEligible("/user.slice/user-1000.slice/session-3.scope"));
}

TEST(Units, UidMin)
{
    EXPECT_EQ(parseUidMin("# comment\nUID_MIN\t\t\t 1000\nUID_MAX 60000\n"), 1000u);
    EXPECT_EQ(parseUidMin("UID_MIN 500\n"), 500u);
    EXPECT_EQ(parseUidMin("SYS_UID_MIN 201\n"), 1000u);
    EXPECT_EQ(parseUidMin("#UID_MIN 400\nUID_MINIMUM 3\n"), 1000u);
    EXPECT_EQ(parseUidMin(""), 1000u);
}
