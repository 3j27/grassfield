// A-S7 (docs/specs/activity.md; ADR-0038 f, AD29; step 3): the runtime folder of a display, and the projection the app
// reads: version 1 from a live writer, the types AM60 gives, at most 256 windows, at most 64 KiB; a stale writer (another
// start time, no process) or anything else is no projection. The watch reads it when it comes, changes and goes.
#include "../fixture.h"
#include "procparse.h"
#include "runtimefiles.h"

#include <QDir>
#include <QFile>
#include <QSignalSpy>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <cstdio>
#include <fstream>
#include <sstream>
#include <unistd.h>

using namespace activity;
using activity_test::Fixture;

namespace {

QByteArray projection(qint64 pid, quint64 start, const char *rest = R"("windows":[{"pid":4242,"app":"foot","idleInhibit":false},{"pid":5000,"app":"mpv","idleInhibit":true}],"notResponding":[4242])")
{
    return QByteArray("{\"v\":1,\"writer\":{\"pid\":") + QByteArray::number(pid) + ",\"start\":" + QByteArray::number(start)
        + "}," + rest + "}";
}

quint64 ownStart()
{
    std::ifstream f("/proc/self/stat");
    std::stringstream text;
    text << f.rdbuf();
    StatFields st;
    return parseStat(text.str(), st, false) ? st.starttime : 0;
}

} // namespace

TEST(RuntimeFiles, OneFolderPerDisplay)
{
    EXPECT_EQ(runtimeFolder(QStringLiteral("/run/user/1000"), QStringLiteral("wayland-1")), QStringLiteral("/run/user/1000/grassfield/activity-wayland-1"));
    EXPECT_EQ(runtimeFolder(QStringLiteral("/run/user/1000/"), QStringLiteral("/tmp/nested/wayland-9")),
              QStringLiteral("/run/user/1000/grassfield/activity-wayland-9"));
    EXPECT_EQ(runtimeFolder(QStringLiteral("/run/user/1000"), QStringLiteral("wl:0 x")), QStringLiteral("/run/user/1000/grassfield/activity-wl_0_x"));
    EXPECT_EQ(runtimeFolder(QString(), QStringLiteral("wayland-1")), QString());
    EXPECT_EQ(runtimeFolder(QStringLiteral("relative"), QStringLiteral("wayland-1")), QString());
    EXPECT_EQ(runtimeFolder(QStringLiteral("/run/user/1000"), QString()), QString());
}

TEST(RuntimeFiles, AProjectionFromALiveWriter)
{
    Fixture fx;
    fx.write("proc/700/stat", Fixture::statLine(700, "quickshell", 'S', 1, 0, 1, 1, 4, 9000));
    const Projection p = parseProjection(projection(700, 9000), fx.proc());
    ASSERT_TRUE(p.valid);
    EXPECT_EQ(p.apps.value(4242), QStringLiteral("foot"));
    EXPECT_EQ(p.apps.value(5000), QStringLiteral("mpv"));
    EXPECT_TRUE(p.idleInhibitors.contains(5000));
    EXPECT_FALSE(p.idleInhibitors.contains(4242));
    EXPECT_EQ(p.notResponding, QSet<int>{4242});
    // Terms: a writer with another start time, or none at all, is stale.
    EXPECT_FALSE(parseProjection(projection(700, 9001), fx.proc()).valid);
    EXPECT_FALSE(parseProjection(projection(701, 9000), fx.proc()).valid);
}

TEST(RuntimeFiles, AnythingElseIsNoProjection)
{
    Fixture fx;
    fx.write("proc/700/stat", Fixture::statLine(700, "quickshell", 'S', 1, 0, 1, 1, 4, 9000));
    const auto invalid = [&](const QByteArray &text) { return !parseProjection(text, fx.proc()).valid; };
    EXPECT_TRUE(invalid(QByteArray("not json")));
    EXPECT_TRUE(invalid(QByteArray("[1,2]")));
    EXPECT_TRUE(invalid(projection(700, 9000).replace("\"v\":1", "\"v\":2")));
    EXPECT_TRUE(invalid(projection(700, 9000).replace("\"v\":1", "\"v\":\"1\"")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[{"pid":"4242","app":"foot","idleInhibit":false}],"notResponding":[])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[{"pid":4242,"app":7,"idleInhibit":false}],"notResponding":[])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[{"pid":4242,"app":"foot","idleInhibit":"no"}],"notResponding":[])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[{"pid":1,"app":"init","idleInhibit":false}],"notResponding":[])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[{"pid":4242.5,"app":"foot","idleInhibit":false}],"notResponding":[])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":[],"notResponding":["4242"])")));
    EXPECT_TRUE(invalid(projection(700, 9000, R"("windows":{},"notResponding":[])")));
    QByteArray many = "\"windows\":[";
    for (int i = 0; i < 257; ++i)
        many += (i ? "," : "") + QByteArray("{\"pid\":") + QByteArray::number(100 + i) + ",\"app\":\"a\",\"idleInhibit\":false}";
    many += "],\"notResponding\":[]";
    EXPECT_TRUE(invalid(projection(700, 9000, many.constData())));
    QByteArray big = projection(700, 9000);
    big.append(QByteArray(kProjectionMax, ' '));
    EXPECT_TRUE(invalid(big));
    EXPECT_FALSE(invalid(projection(700, 9000)));
}

TEST(RuntimeFiles, TheWatchReadsItWhenItComesChangesAndGoes)
{
    QTemporaryDir runtime;
    const QString folder = runtimeFolder(runtime.path(), QStringLiteral("wayland-7"));
    // This test process is the writer: a live one, by the real /proc.
    const qint64 me = getpid();
    ProjectionWatch watch(folder, "/proc");
    EXPECT_FALSE(watch.projection().valid);
    QSignalSpy changed(&watch, &ProjectionWatch::changed);
    // The folder and the file come after the app (the shell makes them when its window opens).
    ASSERT_TRUE(QDir().mkpath(folder));
    const auto write = [&](const QByteArray &text) {
        QFile tmp(folder + QStringLiteral("/windows.json.tmp"));
        ASSERT_TRUE(tmp.open(QIODevice::WriteOnly));
        tmp.write(text);
        tmp.close();
        // As the shell's writer: a rename over the last one.
        ASSERT_EQ(::rename(QFile::encodeName(tmp.fileName()).constData(), QFile::encodeName(folder + QStringLiteral("/windows.json")).constData()), 0);
    };
    write(projection(me, ownStart()));
    ASSERT_TRUE(changed.wait(3000));
    ASSERT_TRUE(watch.projection().valid);
    EXPECT_EQ(watch.projection().notResponding, QSet<int>{4242});
    changed.clear();
    write(projection(me, ownStart(), R"("windows":[{"pid":4242,"app":"foot","idleInhibit":false}],"notResponding":[])"));
    ASSERT_TRUE(changed.wait(3000));
    EXPECT_TRUE(watch.projection().notResponding.isEmpty());
    changed.clear();
    ASSERT_TRUE(QFile::remove(folder + QStringLiteral("/windows.json")));
    ASSERT_TRUE(changed.wait(3000));
    EXPECT_FALSE(watch.projection().valid);
}
