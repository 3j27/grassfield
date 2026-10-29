// AM16's values, AM15's columns per tab, AM38's sleep preventers and AM17's app entries (ADR-0038 step 2a).
#include "columns.h"
#include "desktopapps.h"
#include "format.h"
#include "inhibitors.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace activity;

namespace {

const QLocale kEnglish(QLocale::English, QLocale::UnitedStates);
const QLocale kFrench(QLocale::French, QLocale::France);

} // namespace

TEST(Format, BytesAsFilesShowsThem)
{
    EXPECT_EQ(formatBytes(0, kEnglish), "0 bytes");
    EXPECT_EQ(formatBytes(1, kEnglish), "1 byte");
    EXPECT_EQ(formatBytes(999, kEnglish), "999 bytes");
    EXPECT_EQ(formatBytes(1000, kEnglish), "1 KB");
    EXPECT_EQ(formatBytes(12345, kEnglish), "12 KB");
    EXPECT_EQ(formatBytes(1234567, kEnglish), "1.23 MB");
    EXPECT_EQ(formatBytes(12345678, kEnglish), "12.3 MB");
    EXPECT_EQ(formatBytes(999500, kEnglish), "1.00 MB"); // 999.5 KB rounds into the next unit, as Files
    EXPECT_EQ(formatBytes(1.5e9, kEnglish), "1.50 GB");
    EXPECT_EQ(formatBytes(1234567, kFrench), "1,23 MB"); // the locale's decimal point
    EXPECT_EQ(formatBytes(-1, kEnglish), "—");
}

TEST(Format, CpuTimeShares)
{
    EXPECT_EQ(formatCpuTime(83.456, kEnglish), "0:01:23.45");
    EXPECT_EQ(formatCpuTime(3723.5, kEnglish), "1:02:03.50");
    EXPECT_EQ(formatCpuTime(0, kEnglish), "0:00:00.00");
    EXPECT_EQ(formatCpuTime(83.456, kFrench), "0:01:23,45");
    EXPECT_EQ(formatCpuTime(-1, kEnglish), "—");
    EXPECT_EQ(formatDecimal(12.34, kEnglish), "12.3");
    EXPECT_EQ(formatDecimal(0, kEnglish), "0.0");
    EXPECT_EQ(formatDecimal(150.06, kFrench), "150,1"); // a share of one core can pass 100 (AD4)
    EXPECT_EQ(formatDecimal(-1, kEnglish), "—");
    EXPECT_EQ(formatCount(1234, kEnglish), "1,234");
    EXPECT_EQ(formatCount(12.6, kEnglish), "13");
    EXPECT_EQ(formatCount(-1, kEnglish), "—");
}

TEST(Columns, EachTabsColumnsAndDefaults)
{
    // ADR-0038 "What each tab reads": macOS's defaults; the name always first, PID and User on every tab (AM10).
    for (Tab tab : {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network}) {
        const TabColumns &t = tabColumns(tab);
        ASSERT_FALSE(t.defaults.empty());
        EXPECT_EQ(t.defaults.front(), Column::Name);
        EXPECT_EQ(t.all.front(), Column::Name);
        EXPECT_NE(std::find(t.defaults.begin(), t.defaults.end(), Column::Pid), t.defaults.end());
        EXPECT_NE(std::find(t.defaults.begin(), t.defaults.end(), Column::User), t.defaults.end());
        for (Column c : t.defaults)
            EXPECT_NE(std::find(t.all.begin(), t.all.end(), c), t.all.end());
        EXPECT_NE(std::find(t.defaults.begin(), t.defaults.end(), t.sort), t.defaults.end());
    }
    EXPECT_EQ(tabColumns(Tab::Cpu).sort, Column::CpuPercent);
    EXPECT_EQ(tabColumns(Tab::Memory).sort, Column::Memory);
    EXPECT_EQ(tabColumns(Tab::Energy).sort, Column::EnergyImpact);
    EXPECT_EQ(tabColumns(Tab::Disk).sort, Column::BytesWritten);
    EXPECT_EQ(tabColumns(Tab::Network).sort, Column::SentBytes);
    EXPECT_EQ(columnFromKey(columnKey(Column::ReceivedPackets)), Column::ReceivedPackets);
    EXPECT_FALSE(columnFromKey(QStringLiteral("nope")).has_value());
    EXPECT_EQ(columnTitle(Column::CompressedMemory, false), "Compressed Memory");
    EXPECT_EQ(columnTitle(Column::CompressedMemory, true), "Swapped Memory"); // AM34
    EXPECT_EQ(columnTitle(Column::SentBytes), "Sent Bytes (TCP)");           // AQ2
}

TEST(Columns, ReadOnlyWhatIsShown)
{
    // AD10: Wake Ups' thread turns and Command's command lines are read only while their column is shown.
    const std::vector<Column> defaults = tabColumns(Tab::Cpu).defaults;
    EXPECT_EQ(readsForColumns(Tab::Cpu, defaults), readsForTab(Tab::Cpu));
    EXPECT_EQ(readsForColumns(Tab::Cpu, {Column::Name, Column::WakeUps}) & ReadThreads, static_cast<unsigned>(ReadThreads));
    EXPECT_EQ(readsForColumns(Tab::Cpu, {Column::Name, Column::Command}) & ReadCommand, static_cast<unsigned>(ReadCommand));
    EXPECT_EQ(readsForColumns(Tab::Disk, tabColumns(Tab::Disk).defaults) & (ReadThreads | ReadCommand), 0u);
}

TEST(Inhibitors, SleepOrIdleInBlockMode)
{
    const QList<Inhibitor> list{
        {QStringLiteral("sleep"), QStringLiteral("player"), QStringLiteral("Playing"), QStringLiteral("block"), 1000, 100},
        {QStringLiteral("shutdown:idle"), QStringLiteral("browser"), QStringLiteral("Video"), QStringLiteral("block"), 1000, 101},
        {QStringLiteral("sleep"), QStringLiteral("logind"), QStringLiteral("Prepare"), QStringLiteral("delay"), 0, 102},
        {QStringLiteral("handle-lid-switch"), QStringLiteral("x"), QStringLiteral("y"), QStringLiteral("block"), 1000, 103},
        {QStringLiteral("idle"), QStringLiteral("nobody"), QStringLiteral("z"), QStringLiteral("block"), 1000, 0},
    };
    EXPECT_EQ(sleepPreventers(list), (QSet<int>{100, 101}));
}

TEST(DesktopApps, NameAndThemeIcon)
{
    const QString text = QStringLiteral("[Desktop Entry]\nType=Application\nName=Files\nName[fr]=Fichiers\nIcon=org.grassfield.Files\n"
                                        "[Desktop Action new]\nName=New Window\nIcon=other\n");
    DesktopApp app = parseDesktopApp(text, QStringLiteral("fr_FR"));
    EXPECT_EQ(app.name, "Fichiers");
    EXPECT_EQ(app.icon, "org.grassfield.Files");
    app = parseDesktopApp(text, QStringLiteral("de_DE"));
    EXPECT_EQ(app.name, "Files");
    // AD36: a file named by the entry is not decoded here: the generic glyph.
    EXPECT_EQ(parseDesktopApp(QStringLiteral("[Desktop Entry]\nName=X\nIcon=/home/u/evil.svg\n"), QStringLiteral("en_US")).icon, "");
}

TEST(DesktopApps, FirstDirectoryWinsAndIdsNeverWalk)
{
    QTemporaryDir home, system;
    ASSERT_TRUE(home.isValid() && system.isValid());
    auto write = [](const QString &dir, const QString &id, const QString &name) {
        QDir().mkpath(dir + QStringLiteral("/applications"));
        QFile f(dir + QStringLiteral("/applications/") + id + QStringLiteral(".desktop"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QStringLiteral("[Desktop Entry]\nName=%1\nIcon=%1-icon\n").arg(name).toUtf8());
    };
    write(home.path(), QStringLiteral("foot"), QStringLiteral("Mine"));
    write(system.path(), QStringLiteral("foot"), QStringLiteral("System"));
    write(system.path(), QStringLiteral("org.mozilla.firefox"), QStringLiteral("Firefox"));
    DesktopApps apps({home.path(), system.path()}, QStringLiteral("en_US"));
    EXPECT_EQ(apps.app(QStringLiteral("foot")).name, "Mine");
    EXPECT_EQ(apps.app(QStringLiteral("org.mozilla.firefox")).icon, "Firefox-icon");
    EXPECT_EQ(apps.app(QStringLiteral("../applications/foot")).name, "");
    EXPECT_EQ(apps.app(QStringLiteral("missing")).name, "");
}
