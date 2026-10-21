// Unit tests for apps/appscope.h (gtest). Built and run by scripts/dev/test.sh.
#include "appscope.h"

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
    qputenv("GRASSFIELD_SESSION", "1");
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_DEV");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
}
