// A-S13 (docs/specs/activity.md AM68, AM76; ADR-0038 g; step 4): Efficiency Mode. Available for one of the user's own
// processes in an app unit, never a session process or another owner's (the tooltip says why), nothing without the user
// manager; the unit read again when the item is chosen (a unit it no longer applies to changes nothing); on sets the idle
// weight and falls back to the lowest number on a systemd without it, off unsets it; a failed call says so.
#include "efficiency.h"

#include <QSignalSpy>

#include <gtest/gtest.h>

#include <unistd.h>

using namespace activity;

namespace
{

const std::string kApp = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope";
const std::string kSession = "/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service";

Efficiency::Target target(bool own = true, bool eligible = true, bool session = false, bool efficient = false)
{
    return Efficiency::Target{4242, 9000, QStringLiteral("Foot"), own, eligible, session, efficient};
}

struct Call {
    QString unit;
    quint64 weight = 0;
};

// An Efficiency whose bus calls are recorded and answered with the errors given, in turn ("" for success).
struct Fixture {
    Efficiency e{"/proc"};
    std::vector<Call> calls;
    QStringList answers;
    std::string cgroup = kApp;
    Fixture()
    {
        e.setSupported(true);
        e.setUnitReader([this](int) { return cgroup; });
        e.setCall([this](const QString &unit, quint64 weight, std::function<void(const QString &)> answer) {
            calls.push_back({unit, weight});
            answer(answers.isEmpty() ? QString() : answers.takeFirst());
        });
    }
};

} // namespace

TEST(Efficiency, AvailableForAnOwnAppUnitWithTheReasonOtherwise)
{
    Fixture f;
    EXPECT_FALSE(f.e.available());
    EXPECT_EQ(f.e.reason(), QString()); // nothing selected: no tooltip
    f.e.setTarget(target());
    EXPECT_TRUE(f.e.available());
    EXPECT_EQ(f.e.reason(), QString());
    EXPECT_EQ(f.e.appName(), QStringLiteral("Foot"));
    EXPECT_FALSE(f.e.on());
    f.e.setTarget(target(true, true, false, true));
    EXPECT_TRUE(f.e.on());
    f.e.setTarget(target(true, false));
    EXPECT_FALSE(f.e.available());
    EXPECT_EQ(f.e.reason(), QStringLiteral("This process isn't running as an app."));
    f.e.setTarget(target(true, false, true));
    EXPECT_EQ(f.e.reason(), QStringLiteral("This process is part of your session."));
    f.e.setTarget(target(true, true, true)); // an app unit's name, but the session's process: never
    EXPECT_FALSE(f.e.available());
    EXPECT_EQ(f.e.reason(), QStringLiteral("This process is part of your session."));
    f.e.setTarget(target(false, false));
    EXPECT_EQ(f.e.reason(), QStringLiteral("This process isn't running as an app."));
    // AM76: no user manager, no item at all.
    f.e.setTarget(target());
    QSignalSpy changed(&f.e, &Efficiency::changed);
    f.e.setSupported(false);
    EXPECT_EQ(changed.count(), 1);
    EXPECT_FALSE(f.e.available());
    EXPECT_EQ(f.e.reason(), QString());
    f.e.set(true);
    EXPECT_TRUE(f.calls.empty());
}

TEST(Efficiency, OnIsIdleAndOffUnsetsTheWeight)
{
    Fixture f;
    f.e.setTarget(target());
    QSignalSpy finished(&f.e, &Efficiency::finished);
    f.e.set(true);
    ASSERT_EQ(f.calls.size(), 1u);
    EXPECT_EQ(f.calls[0].unit, QStringLiteral("app-Hyprland-foot-1a2b3c4d.scope"));
    EXPECT_EQ(f.calls[0].weight, kCpuWeightIdle);
    ASSERT_EQ(finished.count(), 1);
    EXPECT_EQ(finished.at(0).at(0).toString(), QString());
    EXPECT_FALSE(f.e.busy());
    f.e.set(false);
    ASSERT_EQ(f.calls.size(), 2u);
    EXPECT_EQ(f.calls[1].weight, kCpuWeightUnset);
}

TEST(Efficiency, AnOlderSystemdGetsTheLowestNumber)
{
    Fixture f;
    f.e.setTarget(target());
    f.answers = {QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs")};
    QSignalSpy finished(&f.e, &Efficiency::finished);
    f.e.set(true);
    ASSERT_EQ(f.calls.size(), 2u);
    EXPECT_EQ(f.calls[0].weight, kCpuWeightIdle);
    EXPECT_EQ(f.calls[1].weight, kCpuWeightMin);
    ASSERT_EQ(finished.count(), 1);
    EXPECT_EQ(finished.at(0).at(0).toString(), QString());
}

TEST(Efficiency, AFailureSaysSoAndTurningOffNeverFallsBack)
{
    Fixture f;
    f.e.setTarget(target(true, true, false, true));
    f.answers = {QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs")};
    QSignalSpy finished(&f.e, &Efficiency::finished);
    f.e.set(false);
    ASSERT_EQ(f.calls.size(), 1u);
    ASSERT_EQ(finished.count(), 1);
    EXPECT_EQ(finished.at(0).at(0).toString(), QStringLiteral("Efficiency Mode couldn't be turned off."));
    f.answers = {QStringLiteral("org.freedesktop.systemd1.NoSuchUnit")};
    f.e.set(true);
    EXPECT_EQ(finished.at(1).at(0).toString(), QStringLiteral("Efficiency Mode couldn't be turned on."));
    EXPECT_EQ(f.calls.size(), 2u); // only InvalidArgs on the idle weight falls back
}

TEST(Efficiency, TheUnitIsReadAgainWhenChosen)
{
    Fixture f;
    f.e.setTarget(target());
    QSignalSpy finished(&f.e, &Efficiency::finished);
    f.cgroup = kSession; // the row was an app's; the process is in the session's unit now
    f.e.set(true);
    EXPECT_TRUE(f.calls.empty());
    EXPECT_EQ(finished.at(0).at(0).toString(), QStringLiteral("This process isn't running as an app."));
    f.cgroup.clear(); // it ended
    f.e.set(true);
    EXPECT_TRUE(f.calls.empty());
    EXPECT_EQ(finished.at(1).at(0).toString(), QStringLiteral("The process has ended."));
}

TEST(Efficiency, TheRealProcessHandleReadsTheUnit)
{
    // Without a reader, through /proc/<pid>: a pid that is not this start time's process changes nothing.
    Efficiency e("/proc");
    e.setSupported(true);
    int calls = 0;
    e.setCall([&](const QString &, quint64, std::function<void(const QString &)>) { ++calls; });
    e.setTarget(Efficiency::Target{static_cast<int>(getpid()), 1, QStringLiteral("x"), true, true, false, false});
    QSignalSpy finished(&e, &Efficiency::finished);
    e.set(true);
    EXPECT_EQ(calls, 0);
    EXPECT_EQ(finished.at(0).at(0).toString(), QStringLiteral("The process has ended."));
}
