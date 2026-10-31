// A-S11 (docs/specs/activity.md AM57, AM58; ADR-0038 AD13, AD45): Inspect's reader. Its parsers on kernel texts; one
// process on a fixture tree, the user's own (every tab) and another owner's (stat and status only: no io, unit, command
// line, links or descriptors); % CPU between two reads; smaps_rollup at most every 5 s; a parent younger than the process
// is no parent (AD40); a process that ended, or whose pid names another process now, reads nothing. Then the real kernel:
// a child of the test with a pipe, a listening TCP socket and a local socket, read through its descriptor until it ends.
#include "fixture.h"
#include "inspect.h"
#include "procparse.h"

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <csignal>
#include <fstream>
#include <netinet/in.h>
#include <sstream>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

using activity::Descriptor;
using activity::InetSocket;
using activity::ProcessDetails;
using activity::ProcessInspector;
using activity_test::Fixture;

namespace
{

constexpr uint32_t kUid = 1000;

// A stat line of a kernel 6.x, every field there (52), the name holding a space and a parenthesis, policy 3 (SCHED_BATCH).
const char *const kStat = "4242 (my (app) 2) S 1 4242 4242 34816 4242 4194304 1046 4524 7 0 150 50 3 1 20 5 4 0 12345 "
                          "8597504 1352 18446744073709551615 94591 94592 140726 0 0 0 65536 3686404 1266761467 1 0 0 17 3 "
                          "0 3 0 0 0 94593 94594 94595 140726 140727 140728 140729 0\n";

void writeOwn(const Fixture &fx, int pid, uint64_t start, unsigned long utime, unsigned uid = kUid, int ppid = 1)
{
    fx.inspectable(pid, start, uid, utime, ppid);
}

std::vector<std::string> texts(const ProcessDetails &d)
{
    std::vector<std::string> out;
    for (const Descriptor &f : d.files) {
        std::string t = std::to_string(f.fd) + " ";
        switch (f.kind) {
        case Descriptor::Kind::File: t += "file " + f.name; break;
        case Descriptor::Kind::Pipe: t += "pipe"; break;
        case Descriptor::Kind::Tcp: t += "tcp " + f.local + (f.remote.empty() ? "" : " " + f.remote) + (f.listening ? " listen" : ""); break;
        case Descriptor::Kind::Udp: t += "udp " + f.local + (f.remote.empty() ? "" : " " + f.remote); break;
        case Descriptor::Kind::Local: t += "local " + f.name; break;
        case Descriptor::Kind::Other: t += "other " + f.name; break;
        }
        out.push_back(t);
    }
    return out;
}

} // namespace

TEST(InspectParsers, StatPolicyAfterTheNamesLastParenthesis)
{
    int policy = -1;
    ASSERT_TRUE(activity::parseStatPolicy(kStat, policy));
    EXPECT_EQ(policy, 3);
    EXPECT_FALSE(activity::parseStatPolicy("4242 (short) S 1 2 3\n", policy));
    EXPECT_FALSE(activity::parseStatPolicy("no parenthesis", policy));
}

TEST(InspectParsers, PssBootTimeAndUnit)
{
    uint64_t bytes = 0;
    ASSERT_TRUE(activity::parseSmapsPss("55d0-7ffc ---p 0 00:00 0 [rollup]\nRss:  4000 kB\nPss:  2500 kB\nPss_Anon: 1 kB\n", bytes));
    EXPECT_EQ(bytes, 2500u * 1024);
    EXPECT_FALSE(activity::parseSmapsPss("Rss: 4000 kB\n", bytes));
    uint64_t btime = 0;
    ASSERT_TRUE(activity::parseBootTime("cpu  1 2 3\ncpu0 1 2 3\nintr 5 6\nctxt 9\nbtime 1761800000\nprocesses 7\n", btime));
    EXPECT_EQ(btime, 1761800000u);
    EXPECT_FALSE(activity::parseBootTime("cpu 1 2 3\n", btime));

    EXPECT_EQ(activity::unitOfCgroup("/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-foot@1a2b.service"),
              "app-Hyprland-foot@1a2b.service");
    // A delegated unit's own groups: the unit, not the group inside it.
    EXPECT_EQ(activity::unitOfCgroup("/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-x-1.scope/sub"),
              "app-flatpak-x-1.scope");
    EXPECT_EQ(activity::unitOfCgroup("/user.slice/user-1000.slice"), "user-1000.slice");
    EXPECT_EQ(activity::unitOfCgroup("/"), "");
    EXPECT_EQ(activity::unitOfCgroup(""), "");
}

TEST(InspectParsers, InetAndLocalSockets)
{
    std::unordered_map<uint64_t, InetSocket> inet;
    activity::parseInetSockets("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                               "   0: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 11 1\n"
                               "   1: 0F02000A:D431 2A00A8C0:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 12 1\n"
                               "   2: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 1\n"
                               "   3: garbage\n",
                               false, true, inet);
    ASSERT_EQ(inet.size(), 2u); // inode 0 (a socket in TIME_WAIT, no owner) and the broken line are left out
    EXPECT_EQ(inet[11].local, "127.0.0.1:631");
    EXPECT_EQ(inet[11].remote, "");
    EXPECT_TRUE(inet[11].listening);
    EXPECT_EQ(inet[12].local, "10.0.2.15:54321");
    EXPECT_EQ(inet[12].remote, "192.168.0.42:443");
    EXPECT_FALSE(inet[12].listening);
    activity::parseInetSockets("  sl  local_address                         remote_address                        st\n"
                               "   0: 00000000000000000000000001000000:0035 00000000000000000000000000000000:0000 07 0:0 0:0 0 "
                               "1000 0 21 2\n"
                               "   1: 00000000000000000000000000000000:14E9 00000000000000000000000000000000:0000 07 0:0 0:0 0 "
                               "1000 0 22 2\n",
                               true, false, inet);
    EXPECT_EQ(inet[21].local, "[::1]:53");
    EXPECT_FALSE(inet[21].tcp);
    EXPECT_FALSE(inet[21].listening); // UDP has no LISTEN
    EXPECT_EQ(inet[22].local, "*:5353");
    EXPECT_EQ(inet[22].remote, "");

    std::unordered_map<uint64_t, std::string> local;
    activity::parseUnixSockets("Num       RefCount Protocol Flags    Type St Inode Path\n"
                               "0000000000000000: 00000002 00000000 00010000 0001 01 31 /run/user/1000/bus\n"
                               "0000000000000000: 00000003 00000000 00000000 0001 03 32\n"
                               "0000000000000000: 00000002 00000000 00010000 0001 01 33 @/tmp/.X11-unix/X0\n"
                               "0000000000000000: 00000002 00000000 00010000 0001 01 34 /tmp/with space\xe2\x80\xae.sock\n",
                               local);
    EXPECT_EQ(local[31], "/run/user/1000/bus");
    EXPECT_EQ(local[32], "");
    EXPECT_EQ(local[33], "@/tmp/.X11-unix/X0");
    EXPECT_EQ(local[34], "/tmp/with space.sock"); // AM17: a right-to-left override is removed
}

TEST(InspectFixture, AnOwnProcessOnEveryTab)
{
    Fixture fx;
    fx.write("proc/stat", "cpu  1 2 3\nbtime 1761800000\n");
    writeOwn(fx, 300, 5000, 100);
    fx.write("proc/1/stat", Fixture::statLine(1, "systemd", 'S', 0, 0, 1, 1, 1, 10));
    ProcessInspector in(fx.proc(), kUid, 100);
    ASSERT_TRUE(in.open(300, 5000));

    ProcessDetails d = in.read(activity::InspectMemory, 10.0);
    ASSERT_TRUE(d.alive);
    EXPECT_TRUE(d.own);
    EXPECT_EQ(d.uid, kUid);
    EXPECT_EQ(d.comm, "worker");
    EXPECT_EQ(d.pgrp, 300);
    EXPECT_TRUE(d.hasParent);
    EXPECT_EQ(d.ppid, 1);
    EXPECT_EQ(d.parentStart, 10u);
    EXPECT_EQ(d.parentComm, "systemd");
    EXPECT_EQ(d.cpuPercent, -1); // the first read
    ASSERT_TRUE(d.hasMemory);
    EXPECT_EQ(d.realMemory, 8000u * 1024);      // VmRSS
    EXPECT_EQ(d.virtualMemory, 200000u * 1024); // VmSize
    EXPECT_EQ(d.sharedMemory, 5000u * 1024);    // RssFile + RssShmem
    EXPECT_EQ(d.privateMemory, 3000u * 1024);   // RssAnon
    EXPECT_EQ(d.swapped, 512u * 1024);          // VmSwap
    EXPECT_EQ(d.peakMemory, 9000u * 1024);      // VmHWM
    EXPECT_EQ(d.proportionalMemory, 2500 * 1024);
    EXPECT_EQ(d.threads, 2);
    EXPECT_DOUBLE_EQ(d.userSeconds, 1.0);
    EXPECT_DOUBLE_EQ(d.systemSeconds, 0.2);
    EXPECT_EQ(d.nice, -5);
    EXPECT_EQ(d.policy, 0);
    EXPECT_DOUBLE_EQ(d.started, 1761800000.0 + 50.0);
    EXPECT_EQ(d.minorFaults, 10u);
    EXPECT_EQ(d.majorFaults, 2u);
    // The Memory tab reads no statistics and no descriptors.
    EXPECT_FALSE(d.hasSwitches);
    EXPECT_EQ(d.readCalls, -1);
    EXPECT_EQ(d.command, "");
    EXPECT_FALSE(d.hasFiles);

    // % CPU between two reads: 100 more ticks (one second at 100 per second) over two seconds.
    writeOwn(fx, 300, 5000, 200);
    d = in.read(activity::InspectStatistics, 12.0);
    EXPECT_DOUBLE_EQ(d.cpuPercent, 50.0);
    ASSERT_TRUE(d.hasSwitches);
    EXPECT_EQ(d.voluntarySwitches, 42u); // the two threads' (status alone gives the main thread's)
    EXPECT_EQ(d.involuntarySwitches, 6u);
    EXPECT_EQ(d.readCalls, 31);
    EXPECT_EQ(d.writeCalls, 17);
    EXPECT_EQ(d.unit, "app-Hyprland-foot@1a2b3c4d.service");
    EXPECT_EQ(d.command, "/usr/bin/worker --quiet");
    EXPECT_EQ(d.executable, "/usr/bin/worker");
    EXPECT_EQ(d.workingFolder, "/home/alice/projects");
    EXPECT_EQ(d.proportionalMemory, -1); // not the Memory tab

    // Off screen, then back: the share starts again (AM8).
    d = in.read(activity::InspectStatistics, 20.0, true);
    EXPECT_EQ(d.cpuPercent, -1);

    d = in.read(activity::InspectFiles, 21.0);
    ASSERT_TRUE(d.hasFiles);
    EXPECT_EQ(texts(d), (std::vector<std::string>{"0 file /home/alice/notes.txt", "1 pipe", "3 tcp 127.0.0.1:8080 listen",
                                                  "4 tcp [::1]:54321 [::ffff:10.0.0.10]:443", "5 local /run/user/1000/bus",
                                                  "10 other anon_inode:[eventfd]", "11 other socket:[7999]"}));
    EXPECT_EQ(d.moreFiles, 0u);
}

// Mutants D13, D14, D16 of step 2d: a path a process chose is sanitized as AM17; Peak Memory never shows below Real Memory
// (AM31); past 10 000 descriptors the rest are counted, not listed.
TEST(InspectFixture, APathIsSanitizedThePeakIsNeverBelowAndTheListIsBounded)
{
    Fixture fx;
    writeOwn(fx, 300, 5000, 100);
    fx.link("/home/alice/invoice\xe2\x80\xae" "fdp.exe", "proc/300/fd/12"); // a right-to-left override
    // VmHWM below VmRSS (the kernel updates the peak lazily).
    fx.write("proc/300/status", "Name:\tworker\nUid:\t1000\t1000\t1000\t1000\nVmHWM:\t  100 kB\nVmRSS:\t  8000 kB\n"
                                "RssAnon:\t  3000 kB\nRssFile:\t  4000 kB\nRssShmem:\t  1000 kB\nVmSwap:\t  0 kB\n");
    ProcessInspector in(fx.proc(), kUid, 100);
    ASSERT_TRUE(in.open(300, 5000));
    ProcessDetails d = in.read(activity::InspectFiles, 1.0);
    ASSERT_TRUE(d.hasFiles);
    bool found = false;
    for (const Descriptor &f : d.files)
        found = found || (f.fd == 12 && f.name == "/home/alice/invoicefdp.exe");
    EXPECT_TRUE(found);
    EXPECT_EQ(d.peakMemory, 8000u * 1024);

    for (size_t fd = 100; fd < 100 + activity::kMaxDescriptors; ++fd)
        fx.link("/dev/null", "proc/300/fd/" + std::to_string(fd));
    d = in.read(activity::InspectFiles, 2.0);
    EXPECT_EQ(d.files.size(), activity::kMaxDescriptors);
    EXPECT_EQ(d.moreFiles, 8u); // the eight of the fixture past the bound (the lowest numbers are listed)
    EXPECT_EQ(d.files.front().fd, 0);
}

TEST(InspectFixture, ProportionalMemoryAtMostEveryFiveSeconds)
{
    Fixture fx;
    writeOwn(fx, 300, 5000, 100);
    ProcessInspector in(fx.proc(), kUid, 100);
    ASSERT_TRUE(in.open(300, 5000));
    EXPECT_EQ(in.read(activity::InspectMemory, 100.0).proportionalMemory, 2500 * 1024);
    fx.write("proc/300/smaps_rollup", "x [rollup]\nPss:  9000 kB\n");
    EXPECT_EQ(in.read(activity::InspectMemory, 101.0).proportionalMemory, 2500 * 1024); // kept: less than 5 s
    EXPECT_EQ(in.read(activity::InspectMemory, 104.9).proportionalMemory, 2500 * 1024);
    EXPECT_EQ(in.read(activity::InspectMemory, 105.0).proportionalMemory, 9000 * 1024);
}

TEST(InspectFixture, AnotherOwnersProcessGivesStatAndStatusOnly)
{
    Fixture fx;
    writeOwn(fx, 400, 6000, 100, 2000); // every file there, as root sees it
    ProcessInspector in(fx.proc(), kUid, 100);
    ASSERT_TRUE(in.open(400, 6000));
    const ProcessDetails d = in.read(activity::InspectMemory | activity::InspectStatistics | activity::InspectFiles, 10.0);
    ASSERT_TRUE(d.alive);
    EXPECT_FALSE(d.own);
    EXPECT_EQ(d.uid, 2000u);
    // AM57: the header, the Memory tab but Proportional, Threads, CPU Time, Context Switches, Faults, Started, Nice.
    EXPECT_TRUE(d.hasMemory);
    EXPECT_EQ(d.realMemory, 8000u * 1024);
    EXPECT_EQ(d.proportionalMemory, -1);
    EXPECT_EQ(d.threads, 2);
    EXPECT_TRUE(d.hasSwitches);
    EXPECT_EQ(d.voluntarySwitches, 42u);
    EXPECT_EQ(d.nice, -5);
    // AD25: never its io, unit, command line, links or descriptors.
    EXPECT_EQ(d.readCalls, -1);
    EXPECT_EQ(d.writeCalls, -1);
    EXPECT_EQ(d.unit, "");
    EXPECT_EQ(d.command, "");
    EXPECT_EQ(d.executable, "");
    EXPECT_EQ(d.workingFolder, "");
    EXPECT_FALSE(d.hasFiles);
    EXPECT_TRUE(d.files.empty());
}

TEST(InspectFixture, AYoungerParentIsAReusedPid)
{
    Fixture fx;
    writeOwn(fx, 300, 5000, 100, kUid, 250);
    fx.write("proc/250/stat", Fixture::statLine(250, "newer", 'S', 1, 0, 1, 1, 1, 9000)); // started after 300
    ProcessInspector in(fx.proc(), kUid, 100);
    ASSERT_TRUE(in.open(300, 5000));
    ProcessDetails d = in.read(0, 1.0);
    EXPECT_EQ(d.ppid, 250);
    EXPECT_FALSE(d.hasParent);
    fx.write("proc/250/stat", Fixture::statLine(250, "shell", 'S', 1, 0, 1, 1, 1, 4000));
    d = in.read(0, 2.0);
    EXPECT_TRUE(d.hasParent);
    EXPECT_EQ(d.parentStart, 4000u);
    EXPECT_EQ(d.parentComm, "shell");
}

TEST(InspectFixture, AnEndedOrReplacedProcessReadsNothing)
{
    Fixture fx;
    writeOwn(fx, 300, 5000, 100);
    ProcessInspector in(fx.proc(), kUid, 100);
    EXPECT_FALSE(in.open(300, 4999)); // AM51: another start time is another process
    EXPECT_FALSE(in.open(301, 5000));
    ASSERT_TRUE(in.open(300, 5000));
    ASSERT_TRUE(in.read(0, 1.0).alive);
    // Its pid now names a process started later.
    fx.write("proc/300/stat", Fixture::statLine(300, "other", 'S', 1, 0, 1, 1, 1, 7000));
    EXPECT_FALSE(in.read(activity::InspectStatistics, 2.0).alive);
    fx.remove("proc/300");
    EXPECT_FALSE(in.read(0, 3.0).alive);
}

TEST(InspectKernel, AChildReadThroughItsDescriptorUntilItEnds)
{
    int pipeFds[2];
    ASSERT_EQ(pipe(pipeFds), 0);
    const int tcp = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    ASSERT_GE(tcp, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ASSERT_EQ(bind(tcp, reinterpret_cast<sockaddr *>(&addr), sizeof addr), 0);
    ASSERT_EQ(listen(tcp, 1), 0);
    socklen_t len = sizeof addr;
    ASSERT_EQ(getsockname(tcp, reinterpret_cast<sockaddr *>(&addr), &len), 0);
    const int unixFd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    ASSERT_GE(unixFd, 0);
    sockaddr_un un{};
    un.sun_family = AF_UNIX;
    const std::string path = "/tmp/activity-inspect-" + std::to_string(getpid()) + ".sock";
    std::snprintf(un.sun_path, sizeof un.sun_path, "%s", path.c_str());
    ASSERT_EQ(bind(unixFd, reinterpret_cast<sockaddr *>(&un), sizeof un), 0);

    const pid_t child = fork();
    if (child == 0) {
        for (;;)
            pause();
    }
    ASSERT_GT(child, 0);
    close(pipeFds[0]);
    close(pipeFds[1]);
    close(tcp);
    close(unixFd);
    unlink(path.c_str());

    std::ifstream f("/proc/" + std::to_string(child) + "/stat");
    std::stringstream text;
    text << f.rdbuf();
    activity::StatFields st;
    ASSERT_TRUE(activity::parseStat(text.str(), st, false));
    ProcessInspector in("/proc", getuid(), sysconf(_SC_CLK_TCK));
    ASSERT_TRUE(in.open(child, st.starttime));
    ProcessDetails d = in.read(activity::InspectStatistics, 1.0);
    ASSERT_TRUE(d.alive);
    EXPECT_TRUE(d.own);
    EXPECT_EQ(d.ppid, getpid());
    EXPECT_TRUE(d.hasParent);
    EXPECT_GE(d.started, 0);
    EXPECT_TRUE(d.hasSwitches);
    EXPECT_GE(d.readCalls, 0);
    EXPECT_FALSE(d.command.empty());
    EXPECT_FALSE(d.executable.empty());
    EXPECT_FALSE(d.workingFolder.empty());
    d = in.read(activity::InspectFiles, 2.0);
    ASSERT_TRUE(d.hasFiles);
    bool pipeSeen = false, listenSeen = false, localSeen = false;
    const std::string port = ":" + std::to_string(ntohs(addr.sin_port));
    for (const Descriptor &fd : d.files) {
        pipeSeen = pipeSeen || fd.kind == Descriptor::Kind::Pipe;
        listenSeen = listenSeen || (fd.kind == Descriptor::Kind::Tcp && fd.listening && fd.local == "127.0.0.1" + port);
        localSeen = localSeen || (fd.kind == Descriptor::Kind::Local && fd.name == path);
    }
    EXPECT_TRUE(pipeSeen);
    EXPECT_TRUE(listenSeen) << "no TCP listener on 127.0.0.1" << port;
    EXPECT_TRUE(localSeen);
    if (geteuid() != 0) {
        // Its parent (this test, the user's own) gives its stat; pid 1 (root's) refuses the descriptors (A1).
        ProcessInspector init("/proc", getuid(), sysconf(_SC_CLK_TCK));
        std::ifstream f1("/proc/1/stat");
        std::stringstream t1;
        t1 << f1.rdbuf();
        activity::StatFields st1;
        if (activity::parseStat(t1.str(), st1, false) && init.open(1, st1.starttime)) {
            const ProcessDetails one = init.read(activity::InspectFiles | activity::InspectStatistics, 1.0);
            EXPECT_FALSE(one.own);
            EXPECT_FALSE(one.hasFiles);
            EXPECT_EQ(one.command, "");
        }
    }

    kill(child, SIGKILL);
    int status = 0;
    ASSERT_EQ(waitpid(child, &status, 0), child);
    EXPECT_FALSE(in.read(activity::InspectStatistics, 3.0).alive);
}
