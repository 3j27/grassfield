// Unit tests for apps/appscope.h (gtest). Built and run by scripts/dev/test.sh.
#include "appscope.h"
#include "chromecaps.h"

#include <gtest/gtest.h>

using grassfield::apps::scopedCommand;

TEST(AppScope, RealSessionStartsTheApplicationThroughUwsmApp)
{
    const QStringList c = scopedCommand(QStringLiteral("grassfield-preview"), {QStringLiteral("--glance"), QStringLiteral("--"), QStringLiteral("/a b.png")}, true);
    EXPECT_EQ(c, (QStringList{QStringLiteral("uwsm-app"), QStringLiteral("--"), QStringLiteral("grassfield-preview"), QStringLiteral("--glance"), QStringLiteral("--"), QStringLiteral("/a b.png")}));
}

TEST(AppScope, UnscopedSessionKeepsTheCommand)
{
    const QStringList c = scopedCommand(QStringLiteral("p"), {QStringLiteral("x")}, false);
    EXPECT_EQ(c, (QStringList{QStringLiteral("p"), QStringLiteral("x")}));
}

TEST(AppScope, DevSessionIsNeverScoped)
{
    qunsetenv("GRASSFIELD_SESSION"); // not inherited from the environment the tests run in
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
    qunsetenv("GRASSFIELD_DEV");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
}

// ADR-0019: a GRASSFIELD_DEV=1 that leaked into a packaged session (GRASSFIELD_SESSION=1) changes nothing there.
TEST(AppScope, ALeakedDevValueInARealSessionChangesNothing)
{
    qputenv("GRASSFIELD_SESSION", "1");
    qunsetenv("GRASSFIELD_DEV");
    const bool plain = grassfield::apps::scopedLaunch();
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(grassfield::apps::scopedLaunch(), plain);
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_DEV");
}

// ADR-0015 Q4(b): the minimize light is greyed only when the shell says the plugin is absent or has no minimize feature.
TEST(ChromeCaps, MinimizeIsAvailableWithThePlugin)
{
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true,"features":["decorations","minimize"]})"));
}

TEST(ChromeCaps, NoPluginOrNoMinimizeFeatureGreysTheLight)
{
    EXPECT_FALSE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":false,"features":[]})"));
    EXPECT_FALSE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true,"features":["decorations"]})"));
}

TEST(ChromeCaps, UnknownStateKeepsTheLightEnabled)
{
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(""));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable("not json"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable("[]"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":2,"pluginPresent":false})"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":"no"})"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true})"));
}

TEST(ChromeCaps, FileLocationFollowsTheDevStateHomeThenTheRuntimeDir)
{
    qputenv("GRASSFIELD_STATE_HOME", "/s");
    EXPECT_EQ(grassfield::apps::capabilitiesFile(), QStringLiteral("/s/capabilities.json"));
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("XDG_RUNTIME_DIR", "/run/user/1");
    EXPECT_EQ(grassfield::apps::capabilitiesFile(), QStringLiteral("/run/user/1/grassfield-capabilities.json"));
}
