#include <gtest/gtest.h>

#include "shortcutstyle.h"

// apps/shortcutstyle.h, the C++ copy of MenuShortcut.macDevice() and style() (ui/Grassfield/Ui/MenuShortcut.js) that Files and
// Preview use: the same cases as tests/unit/tst_menushortcut.qml.
using grassfield::apps::isMacDevice;
using grassfield::apps::shortcutStyle;

namespace {
const QString kAppleKeyboard = QStringLiteral("I: Bus=0003 Vendor=05ac Product=024f Version=0111\nN: Name=\"Apple Inc. Magic Keyboard\"\n"
                                              "H: Handlers=sysrq kbd leds event3\nB: EV=120013\n");
const QString kAppleBluetoothKeyboard = QStringLiteral("I: Bus=0005 Vendor=004c Product=0267 Version=0001\nN: Name=\"Magic Keyboard\"\n"
                                                       "H: Handlers=sysrq kbd leds event7\n");
const QString kAppleTrackpadOnly = QStringLiteral("I: Bus=0003 Vendor=05ac Product=0265 Version=0110\nN: Name=\"Apple Inc. Magic Trackpad\"\n"
                                                  "H: Handlers=mouse2 event5\n");
const QString kPcKeyboard = QStringLiteral("I: Bus=0011 Vendor=0001 Product=0001 Version=ab41\nN: Name=\"AT Translated Set 2 keyboard\"\n"
                                           "H: Handlers=sysrq kbd leds event0\n");
} // namespace

TEST(ShortcutStyle, MacDeviceFromTheFirmwareVendorOrAnAppleKeyboard)
{
    EXPECT_TRUE(isMacDevice(QStringLiteral("Apple Inc.\n"), QString()));
    EXPECT_TRUE(isMacDevice(QStringLiteral("LENOVO"), kPcKeyboard + QStringLiteral("\n") + kAppleKeyboard));
    EXPECT_TRUE(isMacDevice(QString(), kAppleBluetoothKeyboard));
    EXPECT_FALSE(isMacDevice(QStringLiteral("LENOVO"), kPcKeyboard + QStringLiteral("\n") + kAppleTrackpadOnly));
    EXPECT_FALSE(isMacDevice(QString(), QString()));
}

TEST(ShortcutStyle, SettingThenDevice)
{
    EXPECT_EQ(shortcutStyle(QStringLiteral("automatic"), true), QStringLiteral("mac"));
    EXPECT_EQ(shortcutStyle(QStringLiteral("automatic"), false), QStringLiteral("pc"));
    EXPECT_EQ(shortcutStyle(QStringLiteral("mac"), false), QStringLiteral("mac"));
    EXPECT_EQ(shortcutStyle(QStringLiteral("pc"), true), QStringLiteral("pc"));
    EXPECT_EQ(shortcutStyle(QStringLiteral("bogus"), true), QStringLiteral("mac"));
    EXPECT_EQ(shortcutStyle(QString(), false), QStringLiteral("pc"));
}
