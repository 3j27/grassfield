// A-S6 (docs/specs/activity.md; ADR-0038 e, AD30): AM51's path against the real kernel. The stat read through the
// /proc/<pid> descriptor and its start time; the signal through that same descriptor; a process that ended and was reaped
// is never signalled, even after a new process took its pid (in a user and pid namespace of the test's own, where the
// next pid can be chosen; skipped, with the reason, where the kernel refuses such a namespace). AM56's dev roots on a
// fixture tree. AD43's parent: read again through the descriptor after a reparenting, and its unit read through its own
// directory, never a younger process's (step 2d, the integrator's follow-ups on pull request #63).
#include "fixture.h"
#include "procparse.h"
#include "signals.h"

#include <gtest/gtest.h>

#include <csignal>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <sched.h>
#include <sstream>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

using activity::DevRoot;
using activity::ProcessHandle;
using activity_test::Fixture;

namespace
{

uint64_t startOf(const std::string &procRoot, int pid)
{
    std::ifstream f(procRoot + "/" + std::to_string(pid) + "/stat");
    std::stringstream text;
    text << f.rdbuf();
    activity::StatFields st;
    return activity::parseStat(text.str(), st, false) ? st.starttime : 0;
}

// A child that waits for a signal.
pid_t idleChild()
{
    const pid_t pid = fork();
    if (pid == 0) {
        for (;;)
            pause();
    }
    return pid;
}

// How a child ended: its signal, or 0.
int endingSignal(pid_t pid)
{
    int status = 0;
    if (waitpid(pid, &status, 0) != pid)
        return -1;
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

bool writeFile(const std::string &path, const std::string &text)
{
    const int fd = open(path.c_str(), O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    const bool ok = write(fd, text.data(), text.size()) == static_cast<ssize_t>(text.size());
    close(fd);
    return ok;
}

// The pid-reuse case, as the init of a pid namespace of its own with its own /proc mounted on `dir` (made and removed by
// the test, outside the namespace): A (pid 2) is opened, killed and reaped; the next pid is set back so that B takes pid
// 2; the signal through A's descriptor must fail with ESRCH and leave B alive. Exit codes: 0 passed, 77 the namespace's
// /proc or ns_last_pid refused (skip), others a failure. The mount goes with the namespace.
[[noreturn]] void reuseAsInit(const char *dir)
{
    if (mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0)
        _exit(77);
    if (mount("proc", dir, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, nullptr) != 0)
        _exit(77);
    const std::string proc = dir;
    const pid_t a = idleChild();
    if (a != 2)
        _exit(10);
    const uint64_t startA = startOf(proc, a);
    ProcessHandle handle = ProcessHandle::open(proc, a, startA);
    if (!handle.valid())
        _exit(11);
    kill(a, SIGKILL);
    if (endingSignal(a) != SIGKILL)
        _exit(12);
    if (!writeFile(proc + "/sys/kernel/ns_last_pid", "1"))
        _exit(77);
    const pid_t b = idleChild();
    if (b != 2)
        _exit(13); // the pid was not taken again: nothing proven
    const int error = handle.signal(SIGTERM);
    int status = 0;
    const bool bAlive = waitpid(b, &status, WNOHANG) == 0;
    kill(b, SIGKILL);
    waitpid(b, &status, 0);
    if (error != ESRCH)
        _exit(14);
    _exit(bAlive ? 0 : 15);
}

} // namespace

TEST(Signals, AHandleChecksTheStartTime)
{
    const pid_t child = idleChild();
    ASSERT_GT(child, 0);
    const uint64_t start = startOf("/proc", child);
    ASSERT_GT(start, 0u);
    ProcessHandle handle = ProcessHandle::open("/proc", child, start);
    EXPECT_TRUE(handle.valid());
    EXPECT_EQ(handle.pid(), child);
    EXPECT_EQ(handle.ppid(), getpid());
    // A row whose start time differs is another process: dropped (AM51).
    EXPECT_FALSE(ProcessHandle::open("/proc", child, start + 1).valid());
    EXPECT_FALSE(ProcessHandle::open("/proc", 0, 0).valid());
    // The cgroup is read through the descriptor (AM52, AM54).
    EXPECT_FALSE(handle.cgroup().empty());
    kill(child, SIGKILL);
    endingSignal(child);
}

TEST(Signals, TheSignalGoesThroughTheDescriptor)
{
    for (int sig : {SIGTERM, SIGKILL, SIGHUP}) {
        const pid_t child = idleChild();
        ASSERT_GT(child, 0);
        ProcessHandle handle = ProcessHandle::open("/proc", child, startOf("/proc", child));
        ASSERT_TRUE(handle.valid());
        EXPECT_EQ(handle.signal(sig), 0);
        EXPECT_EQ(endingSignal(child), sig);
    }
}

// A process that ended and was reaped: ESRCH (AM53: silent), whatever the kernel does with its pid afterwards.
TEST(Signals, AnEndedProcessIsNeverSignalled)
{
    const pid_t child = idleChild();
    ASSERT_GT(child, 0);
    ProcessHandle handle = ProcessHandle::open("/proc", child, startOf("/proc", child));
    ASSERT_TRUE(handle.valid());
    kill(child, SIGKILL);
    ASSERT_EQ(endingSignal(child), SIGKILL);
    EXPECT_EQ(handle.signal(SIGTERM), ESRCH);
    // A moved handle keeps the descriptor; the one it left names nothing.
    ProcessHandle moved = std::move(handle);
    EXPECT_FALSE(handle.valid());
    EXPECT_EQ(handle.signal(SIGTERM), EBADF);
    EXPECT_EQ(moved.signal(SIGTERM), ESRCH);
}

TEST(Signals, APidTakenAgainIsNeverSignalled)
{
    const uid_t uid = getuid();
    const gid_t gid = getgid();
    // The namespace's /proc goes here; the directory is removed below whatever the case's end (review of 1153365: an empty
    // one was left after each run).
    const char *tmp = std::getenv("TMPDIR");
    std::string dir = std::string(tmp && *tmp ? tmp : "/tmp") + "/activity-signals-proc-XXXXXX";
    ASSERT_NE(mkdtemp(dir.data()), nullptr);
    const pid_t helper = fork();
    ASSERT_GE(helper, 0);
    if (helper == 0) {
        if (unshare(CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS) != 0)
            _exit(77);
        writeFile("/proc/self/setgroups", "deny");
        if (!writeFile("/proc/self/uid_map", "0 " + std::to_string(uid) + " 1")
            || !writeFile("/proc/self/gid_map", "0 " + std::to_string(gid) + " 1"))
            _exit(77);
        const pid_t init = fork();
        if (init == 0)
            reuseAsInit(dir.c_str());
        int status = 0;
        waitpid(init, &status, 0);
        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 20);
    }
    int status = 0;
    const pid_t waited = waitpid(helper, &status, 0);
    rmdir(dir.c_str()); // the mount went with the namespace
    ASSERT_EQ(waited, helper);
    ASSERT_TRUE(WIFEXITED(status));
    if (WEXITSTATUS(status) == 77)
        GTEST_SKIP() << "the kernel refused a user and pid namespace with its own /proc here (seccomp or masked /proc): "
                        "run on a host, or a container with --security-opt seccomp=unconfined,systempaths=unconfined";
    EXPECT_EQ(WEXITSTATUS(status), 0) << "10-13: the namespace's setup; 14: the signal did not fail with ESRCH; 15: the new "
                                         "process with the old pid did not survive";
}

// AM56: a root's own process and its descendants; nothing else; a record that is stale or malformed names nothing.
TEST(Signals, DevRootsNameTheirProcessesAndDescendants)
{
    Fixture f;
    f.write("proc/100/stat", Fixture::statLine(100, "fixture", 'S', 1, 0, 0, 0, 1, 5000));
    f.write("proc/200/stat", Fixture::statLine(200, "child", 'S', 100, 0, 0, 0, 1, 6000));
    f.write("proc/300/stat", Fixture::statLine(300, "grandchild", 'S', 200, 0, 0, 0, 1, 7000));
    f.write("proc/400/stat", Fixture::statLine(400, "owner's", 'S', 1, 0, 0, 0, 1, 8000));
    f.write("dev/fixture.pid", "100\n");
    f.write("dev/fixture.pid.start", "5000\n");
    f.write("dev/stale.pid", "100\n");
    f.write("dev/stale.pid.start", "4999\n");
    f.write("dev/one.pid", "1\n");
    f.write("dev/one.pid.start", "1\n");
    f.write("dev/ended.pid", "400\n");
    f.write("dev/ended.pid.start", "\n");
    const std::string dev = f.proc() + "/../dev/";
    const std::vector<DevRoot> roots = activity::readDevRoots(dev + "fixture.pid:" + dev + "missing.pid:" + dev + "one.pid::" + dev + "ended.pid");
    ASSERT_EQ(roots.size(), 1u);
    EXPECT_EQ(roots[0].pid, 100);
    EXPECT_EQ(roots[0].start, 5000u);
    EXPECT_TRUE(activity::underDevRoot(f.proc(), 100, 5000, 1, roots));
    EXPECT_TRUE(activity::underDevRoot(f.proc(), 300, 7000, 200, roots));
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 400, 8000, 1, roots));
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 100, 5001, 1, roots)); // another process with the root's pid
    // A root whose process ended and whose pid another took: its descendants by pid are not its own.
    f.write("proc/100/stat", Fixture::statLine(100, "taken", 'S', 1, 0, 0, 0, 1, 9000));
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 300, 7000, 200, roots));
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 300, 7000, 200, activity::readDevRoots(dev + "stale.pid")));
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 300, 7000, 200, {}));
    EXPECT_TRUE(activity::readDevRoots("").empty());
    // A parent that cannot be read ends the walk.
    f.write("proc/100/stat", Fixture::statLine(100, "fixture", 'S', 1, 0, 0, 0, 1, 5000));
    f.remove("proc/200");
    EXPECT_FALSE(activity::underDevRoot(f.proc(), 300, 7000, 200, roots));
}

// The integrator's follow-up on pull request #63 (mutant T7): the parent is read again through the descriptor. A grandchild
// whose parent ends is reparented to this test (a subreaper): ppid() keeps the pid the handle was opened with,
// currentPpid() and parentCgroup() follow the new parent.
TEST(Signals, TheParentIsReadAgainThroughTheDescriptor)
{
    ASSERT_EQ(prctl(PR_SET_CHILD_SUBREAPER, 1), 0);
    int up[2], go[2];
    ASSERT_EQ(pipe(up), 0);
    ASSERT_EQ(pipe(go), 0);
    const pid_t child = fork();
    if (child == 0) {
        const pid_t grandchild = idleChild();
        char c = 0;
        if (write(up[1], &grandchild, sizeof grandchild) != sizeof grandchild || read(go[0], &c, 1) != 1)
            _exit(1);
        _exit(0); // the grandchild is orphaned
    }
    ASSERT_GT(child, 0);
    pid_t grandchild = 0;
    ASSERT_EQ(read(up[0], &grandchild, sizeof grandchild), static_cast<ssize_t>(sizeof grandchild));
    ProcessHandle h = ProcessHandle::open("/proc", grandchild, startOf("/proc", grandchild));
    ASSERT_TRUE(h.valid());
    EXPECT_EQ(h.ppid(), child);
    EXPECT_EQ(h.currentPpid(), child);
    const std::string own = h.cgroup(); // the test's unit: every process here shares it
    EXPECT_EQ(h.parentCgroup("/proc"), own);

    ASSERT_EQ(write(go[1], "x", 1), 1);
    EXPECT_EQ(endingSignal(child), 0);
    // Reparented to this process.
    for (int i = 0; i < 100 && h.currentPpid() != getpid(); ++i)
        usleep(10000);
    EXPECT_EQ(h.ppid(), child);
    EXPECT_EQ(h.currentPpid(), getpid());
    EXPECT_EQ(h.parentCgroup("/proc"), own);

    EXPECT_EQ(h.signal(SIGKILL), 0);
    EXPECT_EQ(endingSignal(grandchild), SIGKILL);
    EXPECT_EQ(h.parentCgroup("/proc"), ""); // it ended: its descriptor reads nothing, nor its parent's unit
    prctl(PR_SET_CHILD_SUBREAPER, 0);
    for (int fd : {up[0], up[1], go[0], go[1]})
        close(fd);
}

// AD43, AD40: the parent's unit is read through the parent's own directory, after its stat: a process younger than the
// child under the parent's pid is not its parent, and its unit is never taken for the parent's.
TEST(Signals, TheParentsUnitIsNeverAYoungerProcesss)
{
    Fixture fx;
    fx.write("proc/300/stat", Fixture::statLine(300, "python", 'S', 250, 0, 1, 1, 1, 5000));
    fx.write("proc/250/stat", Fixture::statLine(250, "fish", 'S', 1, 0, 1, 1, 1, 4000));
    fx.write("proc/250/cgroup", "0::/app.slice/app-Hyprland-foot@1a2b.service\n");
    ProcessHandle h = ProcessHandle::open(fx.proc(), 300, 5000);
    ASSERT_TRUE(h.valid());
    EXPECT_EQ(h.parentCgroup(fx.proc()), "/app.slice/app-Hyprland-foot@1a2b.service");
    fx.write("proc/250/stat", Fixture::statLine(250, "other", 'S', 1, 0, 1, 1, 1, 9000)); // started after the child
    EXPECT_EQ(h.parentCgroup(fx.proc()), "");
    // Reparented: the parent now is 251, whatever the handle read when it opened.
    fx.write("proc/251/stat", Fixture::statLine(251, "init", 'S', 0, 0, 1, 1, 1, 10));
    fx.write("proc/251/cgroup", "0::/init.scope\n");
    fx.write("proc/300/stat", Fixture::statLine(300, "python", 'S', 251, 0, 1, 1, 1, 5000));
    EXPECT_EQ(h.ppid(), 250);
    EXPECT_EQ(h.currentPpid(), 251);
    EXPECT_EQ(h.parentCgroup(fx.proc()), "/init.scope");
    fx.remove("proc/251");
    EXPECT_EQ(h.parentCgroup(fx.proc()), "");
}
