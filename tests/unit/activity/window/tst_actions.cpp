// Quit, Force Quit and Send Signal (spec AM50 to AM56; ADR-0038 e, step 2c): the selection's rules, the sheet's processes
// fixed by their descriptors, SIGTERM and SIGKILL to real children, a process that ended is silent, the app itself, a
// session process, a process of an app unit without the shell's projection, the dev guard, and a failed signal.
#include "../fixture.h"
#include "actions.h"
#include "procparse.h"

#include <QSignalSpy>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <csignal>
#include <fstream>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

uint64_t startOf(const std::string &procRoot, int pid)
{
    std::ifstream f(procRoot + "/" + std::to_string(pid) + "/stat");
    std::stringstream text;
    text << f.rdbuf();
    StatFields st;
    return parseStat(text.str(), st, false) ? st.starttime : 0;
}

// A child that waits for a signal; reaped by ending().
pid_t idleChild()
{
    const pid_t pid = fork();
    if (pid == 0) {
        for (;;)
            pause();
    }
    return pid;
}

// How a child ended: its signal, 0 for an exit, -1 while it runs (`wait` false) or when it is not a child.
int ending(pid_t pid, bool wait = true)
{
    int status = 0;
    const pid_t r = waitpid(pid, &status, wait ? 0 : WNOHANG);
    if (r != pid)
        return -1;
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

ProcessActions::Target own(pid_t pid, const char *name = "child")
{
    return {pid, startOf("/proc", pid), QString::fromLatin1(name), true, false};
}

constexpr const char *kPlain = "/user.slice/user-1000.slice/user@1000.service/app.slice/fixture.service";
constexpr const char *kAppUnit = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope";
constexpr const char *kSession = "/user.slice/user-1000.slice/user@1000.service/session.slice/wayland-wm@hyprland.desktop.service";

// The actions on the real /proc, every process in `unit`.
struct Actions {
    explicit Actions(const char *unit = kPlain) : actions("/proc")
    {
        const std::string path = unit;
        actions.setUnitReader([path](const ProcessHandle &) { return path; });
    }
    ProcessActions actions;
};

QStringList titles(const QVariantList &choices)
{
    QStringList out;
    for (const QVariant &c : choices)
        out << c.toMap().value(QStringLiteral("title")).toString();
    return out;
}

// GRASSFIELD_DEV for one test, restored after it.
struct DevSession {
    explicit DevSession(const QByteArray &roots)
        : dev(qgetenv("GRASSFIELD_DEV")), session(qgetenv("GRASSFIELD_SESSION")), had(qEnvironmentVariableIsSet("GRASSFIELD_ACTIVITY_DEV_ROOTS")),
          old(qgetenv("GRASSFIELD_ACTIVITY_DEV_ROOTS"))
    {
        qputenv("GRASSFIELD_DEV", "1");
        qunsetenv("GRASSFIELD_SESSION");
        qputenv("GRASSFIELD_ACTIVITY_DEV_ROOTS", roots);
    }
    ~DevSession()
    {
        dev.isNull() ? qunsetenv("GRASSFIELD_DEV") : qputenv("GRASSFIELD_DEV", dev);
        session.isNull() ? qunsetenv("GRASSFIELD_SESSION") : qputenv("GRASSFIELD_SESSION", session);
        had ? qputenv("GRASSFIELD_ACTIVITY_DEV_ROOTS", old) : qunsetenv("GRASSFIELD_ACTIVITY_DEV_ROOTS");
    }
    QByteArray dev, session;
    bool had;
    QByteArray old;
};

} // namespace

// AM50: the user's own processes only; never another owner's or the Kernel row; Send Signal on one row.
TEST(ProcessActions, OnlyOwnProcessesCanBeActedOn)
{
    ProcessActions a("/proc");
    QSignalSpy changed(&a, &ProcessActions::selectionChanged);
    EXPECT_FALSE(a.canQuit());
    EXPECT_EQ(a.refusal(), "");
    a.setSelection({{100, 1, QStringLiteral("mine"), true, false}});
    EXPECT_TRUE(a.canQuit());
    EXPECT_TRUE(a.canSignal());
    EXPECT_EQ(a.refusal(), "");
    a.setSelection({{100, 1, QStringLiteral("mine"), true, false}, {101, 1, QStringLiteral("mine too"), true, false}});
    EXPECT_TRUE(a.canQuit());
    EXPECT_FALSE(a.canSignal());
    a.setSelection({{100, 1, QStringLiteral("mine"), true, false}, {1, 1, QStringLiteral("systemd"), false, false}});
    EXPECT_FALSE(a.canQuit());
    EXPECT_FALSE(a.canSignal());
    EXPECT_EQ(a.refusal(), "You can only quit your own processes.");
    a.setSelection({{-1, 0, QStringLiteral("Kernel"), false, true}});
    EXPECT_FALSE(a.canQuit());
    EXPECT_EQ(a.refusal(), "You can only quit your own processes.");
    // The Kernel row is never acted on, even where its owner is the app's (an app run as root).
    a.setSelection({{-1, 0, QStringLiteral("Kernel"), true, true}});
    EXPECT_FALSE(a.canQuit());
    EXPECT_FALSE(a.canSignal());
    a.setSelection({{-1, 0, QStringLiteral("Kernel"), false, true}});
    // No sheet for a selection it may not act on.
    EXPECT_FALSE(a.prepare(QStringLiteral("quit")).value(QStringLiteral("ok")).toBool());
    const int before = static_cast<int>(changed.count());
    a.setSelection({{-1, 0, QStringLiteral("Kernel"), false, true}});
    EXPECT_EQ(changed.count(), before); // the same selection again changes nothing
}

// AM52: Quit of a process without windows, outside an app unit: SIGTERM, through the descriptor.
TEST(ProcessActions, QuitSendsTerminate)
{
    Actions t;
    const pid_t child = idleChild();
    t.actions.setSelection({own(child)});
    const QVariantMap sheet = t.actions.prepare(QStringLiteral("quit"));
    ASSERT_TRUE(sheet.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(sheet.value(QStringLiteral("count")).toInt(), 1);
    EXPECT_EQ(sheet.value(QStringLiteral("name")).toString(), "child");
    EXPECT_EQ(sheet.value(QStringLiteral("pid")).toInt(), child);
    EXPECT_EQ(sheet.value(QStringLiteral("session")).toString(), "");
    EXPECT_FALSE(sheet.value(QStringLiteral("self")).toBool());
    EXPECT_TRUE(t.actions.quit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(ending(child), SIGTERM);
    t.actions.release();
}

// AM53: Force Quit is SIGKILL, for every process of the sheet.
TEST(ProcessActions, ForceQuitKills)
{
    Actions t;
    const pid_t a = idleChild(), b = idleChild();
    t.actions.setSelection({own(a, "a"), own(b, "b")});
    EXPECT_EQ(t.actions.prepare(QStringLiteral("quit")).value(QStringLiteral("count")).toInt(), 2);
    EXPECT_TRUE(t.actions.forceQuit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(ending(a), SIGKILL);
    EXPECT_EQ(ending(b), SIGKILL);
}

// AM51, AM53: a row whose process ended or changed is dropped when the sheet opens; one that ends while the sheet is open
// is silent; the sheet's descriptors were opened before, so the signal can reach no other process.
TEST(ProcessActions, AnEndedProcessIsDroppedOrSilent)
{
    Actions t;
    const pid_t gone = idleChild(), changed = idleChild(), kept = idleChild();
    ProcessActions::Target other = own(changed, "changed");
    other.start += 1;
    kill(gone, SIGKILL);
    ending(gone);
    t.actions.setSelection({own(gone, "gone"), other, own(kept, "kept")});
    QVariantMap sheet = t.actions.prepare(QStringLiteral("quit"));
    EXPECT_EQ(sheet.value(QStringLiteral("count")).toInt(), 1);
    EXPECT_EQ(sheet.value(QStringLiteral("name")).toString(), "kept");
    kill(kept, SIGKILL);
    ending(kept);
    const QVariantMap result = t.actions.forceQuit();
    EXPECT_TRUE(result.value(QStringLiteral("done")).toBool());
    EXPECT_EQ(result.value(QStringLiteral("error")).toString(), "");
    EXPECT_EQ(ending(changed, false), -1); // the changed row's process was never signalled
    kill(changed, SIGKILL);
    ending(changed);
    // Nothing left: no sheet.
    t.actions.setSelection({own(gone, "gone")});
    EXPECT_FALSE(t.actions.prepare(QStringLiteral("quit")).value(QStringLiteral("ok")).toBool());
}

// AM54: the app's own row: Quit closes its window, Force Quit and signals are refused, no Stop is offered.
TEST(ProcessActions, TheAppItself)
{
    Actions t;
    QSignalSpy close(&t.actions, &ProcessActions::closeWindowRequested);
    t.actions.setSelection({own(getpid(), "Activity Monitor")});
    QVariantMap sheet = t.actions.prepare(QStringLiteral("quit"));
    EXPECT_TRUE(sheet.value(QStringLiteral("self")).toBool());
    EXPECT_EQ(t.actions.forceQuit().value(QStringLiteral("error")).toString(), "This app can't force quit itself.");
    EXPECT_EQ(close.count(), 0);
    EXPECT_TRUE(t.actions.quit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(close.count(), 1);
    sheet = t.actions.prepare(QStringLiteral("signal"));
    EXPECT_FALSE(titles(sheet.value(QStringLiteral("signals")).toList()).contains("Stop (SIGSTOP)"));
    EXPECT_EQ(t.actions.send(SIGTERM).value(QStringLiteral("error")).toString(), "This app can't force quit itself.");
    // With another process: Quit signals it and closes the window too.
    const pid_t child = idleChild();
    t.actions.setSelection({own(getpid(), "Activity Monitor"), own(child)});
    t.actions.prepare(QStringLiteral("quit"));
    EXPECT_TRUE(t.actions.quit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(close.count(), 2);
    EXPECT_EQ(ending(child), SIGTERM);
}

// AM54, AM55: a session process is named for the second sheet; Stop is not offered nor sent; the other signals are.
TEST(ProcessActions, ASessionProcess)
{
    Actions t(kSession);
    const pid_t child = idleChild();
    t.actions.setSelection({own(child, "Hyprland")});
    QVariantMap sheet = t.actions.prepare(QStringLiteral("signal"));
    EXPECT_EQ(sheet.value(QStringLiteral("session")).toString(), "Hyprland");
    const QStringList offered = titles(sheet.value(QStringLiteral("signals")).toList());
    EXPECT_EQ(offered.size(), 10);
    EXPECT_FALSE(offered.contains("Stop (SIGSTOP)"));
    EXPECT_EQ(offered.first(), "Hangup (SIGHUP)");
    EXPECT_EQ(offered.last(), "Continue (SIGCONT)");
    EXPECT_EQ(t.actions.send(SIGSTOP).value(QStringLiteral("error")).toString(), "The signal couldn't be sent.");
    EXPECT_EQ(ending(child, false), -1);
    EXPECT_EQ(t.actions.send(99).value(QStringLiteral("error")).toString(), "The signal couldn't be sent.");
    // A session process is quit by SIGTERM once the second sheet is passed (the window asks; AM54).
    sheet = t.actions.prepare(QStringLiteral("quit"));
    EXPECT_EQ(sheet.value(QStringLiteral("session")).toString(), "Hyprland");
    EXPECT_TRUE(t.actions.quit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(ending(child), SIGTERM);
}

// AM55: the signal chosen reaches the process; the full list offers Stop to an ordinary process.
TEST(ProcessActions, SendSignal)
{
    Actions t;
    const pid_t child = idleChild();
    t.actions.setSelection({own(child)});
    const QVariantMap sheet = t.actions.prepare(QStringLiteral("signal"));
    const QStringList offered = titles(sheet.value(QStringLiteral("signals")).toList());
    EXPECT_EQ(offered,
              (QStringList{"Hangup (SIGHUP)", "Interrupt (SIGINT)", "Quit (SIGQUIT)", "Abort (SIGABRT)", "Kill (SIGKILL)",
                           "Alarm (SIGALRM)", "Terminate (SIGTERM)", "User Defined 1 (SIGUSR1)", "User Defined 2 (SIGUSR2)",
                           "Stop (SIGSTOP)", "Continue (SIGCONT)"}));
    EXPECT_TRUE(t.actions.send(SIGUSR1).value(QStringLiteral("done")).toBool());
    EXPECT_EQ(ending(child), SIGUSR1);
    // Two rows: no Send Signal sheet.
    const pid_t a = idleChild(), b = idleChild();
    t.actions.setSelection({own(a), own(b)});
    EXPECT_FALSE(t.actions.prepare(QStringLiteral("signal")).value(QStringLiteral("ok")).toBool());
    kill(a, SIGKILL);
    kill(b, SIGKILL);
    ending(a);
    ending(b);
}

// AM52: without the shell's projection (step 3), a process of an app unit may own windows: Quit sends nothing and the sheet
// offers Force Quit only.
TEST(ProcessActions, AnAppUnitProcessIsNotQuitByASignal)
{
    Actions t(kAppUnit);
    const pid_t child = idleChild();
    t.actions.setSelection({own(child, "foot")});
    t.actions.prepare(QStringLiteral("quit"));
    QVariantMap result = t.actions.quit();
    EXPECT_FALSE(result.value(QStringLiteral("done")).toBool());
    EXPECT_TRUE(result.value(QStringLiteral("unsafe")).toBool());
    EXPECT_EQ(result.value(QStringLiteral("error")).toString(), "The process couldn't be quit safely.");
    EXPECT_EQ(ending(child, false), -1);
    EXPECT_TRUE(t.actions.forceQuit().value(QStringLiteral("done")).toBool());
    EXPECT_EQ(ending(child), SIGKILL);
    const pid_t a = idleChild(), b = idleChild();
    t.actions.setSelection({own(a), own(b)});
    t.actions.prepare(QStringLiteral("quit"));
    EXPECT_EQ(t.actions.quit().value(QStringLiteral("error")).toString(), "These processes couldn't all be quit safely.");
    t.actions.forceQuit();
    EXPECT_EQ(ending(a), SIGKILL);
    EXPECT_EQ(ending(b), SIGKILL);
}

// AM56: in a dev session only a process a dev root names, or one of its descendants, is acted on; the others are refused
// with the sheet's message, and nothing is sent.
TEST(ProcessActions, TheDevGuard)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString record = dir.filePath(QStringLiteral("fixture.pid"));
    {
        std::ofstream(record.toStdString()) << getpid() << "\n";
        std::ofstream(record.toStdString() + ".start") << startOf("/proc", getpid()) << "\n";
    }
    Actions t;
    const pid_t child = idleChild();
    {
        DevSession dev{QByteArray()}; // no root named
        t.actions.setSelection({own(child)});
        t.actions.prepare(QStringLiteral("quit"));
        EXPECT_EQ(t.actions.quit().value(QStringLiteral("error")).toString(),
                  "Development session: only the nested session's processes can be quit.");
        EXPECT_EQ(t.actions.forceQuit().value(QStringLiteral("error")).toString(),
                  "Development session: only the nested session's processes can be quit.");
        EXPECT_EQ(ending(child, false), -1);
    }
    {
        DevSession dev(record.toLocal8Bit());
        t.actions.prepare(QStringLiteral("quit"));
        EXPECT_TRUE(t.actions.forceQuit().value(QStringLiteral("done")).toBool());
        EXPECT_EQ(ending(child), SIGKILL);
    }
}

// AM53: an error other than ESRCH shows the sheet's message (a fixture's directory is no pidfd).
TEST(ProcessActions, AFailedSignalIsShown)
{
    Fixture f;
    f.write("proc/4242/stat", Fixture::statLine(4242, "fixture", 'S', 1, 0, 0, 0, 1, 777));
    f.write("proc/4242/cgroup", std::string("0::") + kPlain + "\n");
    ProcessActions a(f.proc());
    a.setSelection({{4242, 777, QStringLiteral("fixture"), true, false}});
    ASSERT_TRUE(a.prepare(QStringLiteral("quit")).value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(a.quit().value(QStringLiteral("error")).toString(), "The process couldn't be quit.");
    EXPECT_EQ(a.forceQuit().value(QStringLiteral("error")).toString(), "The process couldn't be quit.");
    a.setSelection({{4242, 777, QStringLiteral("fixture"), true, false}});
    a.prepare(QStringLiteral("signal"));
    EXPECT_EQ(a.send(SIGHUP).value(QStringLiteral("error")).toString(), "The signal couldn't be sent.");
    EXPECT_EQ(a.send(SIGTERM).value(QStringLiteral("error")).toString(), "The signal couldn't be sent."); // the action's words
    // The unit is read through the descriptor: the fixture's session unit names the second sheet's process.
    f.write("proc/4242/cgroup", std::string("0::") + kSession + "\n");
    EXPECT_EQ(a.prepare(QStringLiteral("quit")).value(QStringLiteral("session")).toString(), "fixture");
}
