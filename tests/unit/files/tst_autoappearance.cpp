// Unit tests for apps/autoappearance.h (gtest): the Auto appearance schedule of Files and Preview.
#include "autoappearance.h"

#include <gtest/gtest.h>

using grassfield::apps::isDarkAppearance;

TEST(AutoAppearance, LightAndDarkIgnoreTheClock)
{
    EXPECT_FALSE(isDarkAppearance(QStringLiteral("light"), QTime(23, 0)));
    EXPECT_TRUE(isDarkAppearance(QStringLiteral("dark"), QTime(12, 0)));
    EXPECT_TRUE(isDarkAppearance(QStringLiteral("garbage"), QTime(12, 0)));
}

TEST(AutoAppearance, AutoIsDarkFromSevenInTheEveningToSevenInTheMorning)
{
    const QString a = QStringLiteral("auto");
    EXPECT_FALSE(isDarkAppearance(a, QTime(12, 0)));
    EXPECT_FALSE(isDarkAppearance(a, QTime(7, 0)));
    EXPECT_FALSE(isDarkAppearance(a, QTime(18, 59)));
    EXPECT_TRUE(isDarkAppearance(a, QTime(19, 0)));
    EXPECT_TRUE(isDarkAppearance(a, QTime(23, 59)));
    EXPECT_TRUE(isDarkAppearance(a, QTime(0, 0)));
    EXPECT_TRUE(isDarkAppearance(a, QTime(6, 59)));
}
