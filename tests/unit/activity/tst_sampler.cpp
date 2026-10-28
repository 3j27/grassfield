// The activity monitor's sampler on fake /proc and /sys trees (apps/activity/src/sampler.cpp; ADR-0038 b to d;
// docs/specs/activity.md AM17, AM20 to AM29, AM41 to AM49, acceptance A-S1, A-S2, A-S9): owners and names, the Kernel row,
// rates, a pid reused, a process that ends, the turns of the costly reads, GPU clients, the AM29 shares, disks and
// interfaces, the kept-descriptor budget.
#include "fixture.h"
#include "sampler.h"

#include <algorithm>

#include <unistd.h>

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

constexpr uint32_t kMe = 1000;
const std::string user = "/user.slice/user-1000.slice/user@1000.service";

Options options(const Fixture &f, uint32_t uid = kMe)
{
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    o.uid = uid;
    o.uidMin = 1000;
    o.clockTicks = 100;
    o.maxKeptFiles = 4096;
    return o;
}

const ProcessRow *row(const Snapshot &s, int pid)
{
    for (const ProcessRow &r : s.rows) {
        if (r.pid == pid)
            return &r;
    }
    return nullptr;
}

std::string nul(std::initializer_list<const char *> words)
{
    std::string s;
    for (const char *w : words) {
        s += w;
        s += '\0';
    }
    return s;
}

} // namespace

TEST(Sampler, OwnersNamesKindsAndTheKernelRow)
{
    Fixture f;
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot", "--server"}), user + "/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope");
    // Another person's process rewrote its argv[0] into a title: its name must be the kernel's short name (AD25).
    f.process(200, "sshd", 1001, 10, 5000, nul({"sshd: bob@pts/0"}), "/user.slice/user-1001.slice/session-4.scope");
    f.process(300, "systemd-journal", 0, 10, 100, nul({"/usr/lib/systemd/systemd-journald"}), "/system.slice/systemd-journald.service");
    f.process(2, "kthreadd", 0, 40, 1, "", "/", kPfKthread);
    f.process(3, "kworker/0:1", 0, 60, 2, "", "/", kPfKthread);
    // An own process whose name carries a right-to-left override and a control character.
    f.process(400, "evil", kMe, 0, 6000, nul({"/tmp/evil\u202Etxt.exe\x1b"}), user + "/app.slice/x.service");
    f.process(500, "grassfield-shel", kMe, 0, 7000, nul({"/usr/bin/qs", "-p", "/usr/share/grassfield/shell"}), user + "/session.slice/grassfield-shell.service");
    Sampler s(options(f));
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadCommand, 10.0);

    ASSERT_EQ(snap.rows.size(), 5u); // the two kernel threads are summed, not listed
    EXPECT_EQ(snap.kernel.threads, 2);
    EXPECT_EQ(snap.kernel.cpuTicks, 100u);
    EXPECT_LT(snap.kernel.cpuPercent, 0); // no rate at the first sample

    const ProcessRow *foot = row(snap, 100);
    ASSERT_NE(foot, nullptr);
    EXPECT_TRUE(foot->own);
    EXPECT_EQ(foot->name, "foot");
    EXPECT_EQ(foot->command, "/usr/bin/foot --server");
    EXPECT_EQ(foot->kind, Kind::App);
    EXPECT_TRUE(foot->efficiencyEligible);
    EXPECT_FALSE(foot->session);
    EXPECT_TRUE(foot->hasMemory);
    EXPECT_EQ(foot->memory, 1000u * 1024); // RssAnon + VmSwap (AD6)

    const ProcessRow *sshd = row(snap, 200);
    ASSERT_NE(sshd, nullptr);
    EXPECT_FALSE(sshd->own);
    EXPECT_FALSE(sshd->systemAccount);
    EXPECT_EQ(sshd->kind, Kind::OtherUser);
    EXPECT_EQ(sshd->name, "sshd");
    EXPECT_EQ(sshd->command, ""); // never read for another owner
    EXPECT_FALSE(sshd->session);  // the session tests apply to the user's own processes only
    EXPECT_FALSE(sshd->efficiencyEligible);

    const ProcessRow *journald = row(snap, 300);
    ASSERT_NE(journald, nullptr);
    EXPECT_TRUE(journald->systemAccount);
    EXPECT_EQ(journald->kind, Kind::System);
    EXPECT_EQ(journald->name, "systemd-journal");

    const ProcessRow *evil = row(snap, 400);
    ASSERT_NE(evil, nullptr);
    EXPECT_EQ(evil->name, "eviltxt.exe"); // AM17: the override and the escape are gone
    EXPECT_EQ(evil->kind, Kind::Background);

    const ProcessRow *shell = row(snap, 500);
    ASSERT_NE(shell, nullptr);
    EXPECT_EQ(shell->name, "qs");
    EXPECT_TRUE(shell->session);
    EXPECT_EQ(shell->kind, Kind::Session);
    EXPECT_FALSE(shell->efficiencyEligible);
    EXPECT_EQ(snap.counters.cmdlineReads, 3u); // the own processes only
}

TEST(Sampler, WithoutStatusTheDirectoryOwnerDecidesAndNoCmdlineIsReadForOthers)
{
    Fixture f;
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot"}), user + "/app.slice/x.service");
    // The fixture's directories belong to whoever runs the test: with a uid of the app other than theirs, every process is
    // another owner's and is named from stat.
    const uint32_t runner = getuid();
    Sampler other(options(f, runner + 1));
    const Snapshot a = other.sample(ReadProcesses, 1.0);
    ASSERT_EQ(a.rows.size(), 1u);
    if (runner != 0) { // as root, a directory owned by root makes the sampler read status, which names uid 1000
        EXPECT_FALSE(a.rows[0].own);
        EXPECT_EQ(a.counters.cmdlineReads, 0u);
        EXPECT_EQ(a.counters.statusReads, 0u);
    }
    Sampler mine(options(f, runner));
    const Snapshot b = mine.sample(ReadProcesses, 1.0);
    if (runner != 0) {
        EXPECT_TRUE(b.rows[0].own);
        EXPECT_EQ(b.rows[0].name, "foot");
        EXPECT_EQ(b.counters.statusReads, 0u); // the CPU tab reads no status where the directory owner is not root
    }
}

TEST(Sampler, CpuRateAndTheKernelRowRate)
{
    Fixture f;
    f.process(100, "busy", kMe, 1000, 5000, nul({"busy"}), user + "/app.slice/x.service");
    f.process(2, "kworker", 0, 10, 1, "", "/", kPfKthread);
    Sampler s(options(f));
    const Snapshot first = s.sample(ReadProcesses, 10.0);
    EXPECT_LT(row(first, 100)->cpuPercent, 0);
    f.write("proc/100/stat", Fixture::statLine(100, "busy", 'R', 1, 0, 1150, 50, 4, 5000));
    f.write("proc/2/stat", Fixture::statLine(2, "kworker", 'I', 0, kPfKthread, 30, 0, 1, 1));
    const Snapshot second = s.sample(ReadProcesses, 12.0);
    // 200 ticks over 2 s at 100 ticks a second: one core's share is 100 % (AM20).
    EXPECT_DOUBLE_EQ(row(second, 100)->cpuPercent, 100.0);
    EXPECT_EQ(row(second, 100)->threads, 4);
    EXPECT_EQ(row(second, 100)->cpuTicks, 1200u);
    EXPECT_DOUBLE_EQ(second.kernel.cpuPercent, 10.0);
}

TEST(Sampler, APidReusedIsAnotherProcess)
{
    Fixture f;
    f.process(100, "old", kMe, 500, 5000, nul({"/usr/bin/old"}), user + "/app.slice/x.service");
    Sampler s(options(f));
    s.sample(ReadProcesses, 1.0);
    // Same pid, another start time: another process (row identity, the spec's Terms).
    f.process(100, "new", kMe, 10, 9000, nul({"/usr/bin/new"}), user + "/app.slice/y.service");
    const Snapshot snap = s.sample(ReadProcesses, 2.0);
    const ProcessRow *r = row(snap, 100);
    ASSERT_NE(r, nullptr);
    EXPECT_EQ(r->start, 9000u);
    EXPECT_EQ(r->name, "new");
    EXPECT_LT(r->cpuPercent, 0); // no rate from the old process's ticks
    EXPECT_EQ(r->cgroup, user + "/app.slice/y.service");
}

TEST(Sampler, AProcessThatEndsGoesAndItsDescriptorsClose)
{
    Fixture f;
    f.process(100, "a", kMe, 1, 1, nul({"a"}), "/");
    f.process(101, "b", kMe, 1, 1, nul({"b"}), "/");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus, 1.0);
    EXPECT_EQ(s.keptFiles(), 4u); // stat and status of two processes
    f.remove("proc/101");
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus, 2.0);
    EXPECT_EQ(snap.rows.size(), 1u);
    EXPECT_EQ(row(snap, 101), nullptr);
    EXPECT_EQ(s.keptFiles(), 2u);
}

TEST(Sampler, TheKeptDescriptorBudgetHolds)
{
    Fixture f;
    for (int pid = 100; pid < 110; ++pid)
        f.process(pid, "p", kMe, 1, 1, nul({"p"}), "/");
    Options o = options(f);
    o.maxKeptFiles = 3;
    Sampler s(o);
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus, 1.0);
    EXPECT_EQ(snap.rows.size(), 10u);
    EXPECT_EQ(s.keptFiles(), 3u);
    for (int pid = 100; pid < 110; ++pid)
        f.write("proc/" + std::to_string(pid) + "/stat", Fixture::statLine(pid, "p", 'S', 1, 0, 101, 0, 1, 1));
    const Snapshot again = s.sample(ReadProcesses | ReadStatus, 2.0);
    for (const ProcessRow &r : again.rows)
        EXPECT_DOUBLE_EQ(r.cpuPercent, 100.0); // read through kept and unkept files alike
}

TEST(Sampler, DiskBytesOfOwnProcessesOnly)
{
    Fixture f;
    f.process(100, "writer", kMe, 1, 1, nul({"writer"}), "/");
    f.process(200, "theirs", 1001, 1, 1, nul({"theirs"}), "/");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 1000\nwrite_bytes: 2000\ncancelled_write_bytes: 0\n");
    f.write("proc/200/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 5\nwrite_bytes: 5\ncancelled_write_bytes: 0\n");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus | ReadIo, 1.0);
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 5000\nwrite_bytes: 2000\ncancelled_write_bytes: 0\n");
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadIo, 3.0);
    const ProcessRow *w = row(snap, 100);
    ASSERT_TRUE(w->hasIo);
    EXPECT_EQ(w->bytesRead, 5000u);
    EXPECT_EQ(w->bytesWritten, 2000u);
    EXPECT_DOUBLE_EQ(w->readRate, 2000.0);
    EXPECT_DOUBLE_EQ(w->writeRate, 0.0);
    EXPECT_FALSE(row(snap, 200)->hasIo); // another owner's io is never read (the kernel would refuse it, A1)
    EXPECT_EQ(snap.counters.ioReads, 1u);
}

TEST(Sampler, EnergyImpactFormula)
{
    EXPECT_DOUBLE_EQ(energyImpact(10, -1, 50, 2e6, 1e6), 14.0); // 10 + 0 + 0.02 × 50 + 1.0 × 3 MB/s (AM36)
    EXPECT_DOUBLE_EQ(energyImpact(0, 30, 0, 0, 0), 30.0);
    EXPECT_DOUBLE_EQ(energyImpact(-1, -1, -1, -1, -1), 0.0); // unknown terms count as 0
}

TEST(Sampler, EnergyImpactOfOwnProcessesWithItsAverage)
{
    Fixture f;
    f.process(100, "app", kMe, 0, 1, nul({"app"}), "/");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n");
    f.write("proc/100/task/100/status", Fixture::statusText("app", kMe, 1, 0, 0));
    f.process(200, "theirs", 1001, 0, 1, nul({"theirs"}), "/");
    Options o = options(f);
    o.threadTurns = 1; // every process's wake-ups at every sample
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Energy) | ReadStatus;
    const Snapshot first = s.sample(reads, 10.0);
    EXPECT_LT(row(first, 100)->energyImpact, 0); // no CPU share at a process's first sample
    EXPECT_LT(first.energyImpact, 0);
    // Over 2 s: 100 ticks (50 % of one core), 1 000 wake-ups (500 a second), 4 MB read and 2 MB written (3 MB a second).
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 100, 0, 1, 1));
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 4000000\nwrite_bytes: 2000000\ncancelled_write_bytes: 0\n");
    f.write("proc/100/task/100/status", Fixture::statusText("app", kMe, 1, 0, 1000));
    f.write("proc/200/stat", Fixture::statLine(200, "theirs", 'S', 1, 0, 100, 0, 1, 1));
    const Snapshot second = s.sample(reads, 12.0);
    // 50 + 0 (no GPU client) + 0.02 × 500 + 1.0 × 3 = 63 (AM36).
    EXPECT_DOUBLE_EQ(row(second, 100)->energyImpact, 63.0);
    EXPECT_DOUBLE_EQ(row(second, 100)->averageEnergyImpact, 63.0);
    EXPECT_DOUBLE_EQ(row(second, 200)->cpuPercent, 50.0);
    EXPECT_LT(row(second, 200)->energyImpact, 0); // another owner's: its io and descriptors are refused, so "—"
    EXPECT_DOUBLE_EQ(second.energyImpact, 63.0);  // the graph sums the user's own processes (AM39)
    // Then 6 s idle: 0, and the average weighted by time is (63 × 2 + 0 × 6) ÷ 8 (AM37).
    const Snapshot third = s.sample(reads, 18.0);
    EXPECT_DOUBLE_EQ(row(third, 100)->energyImpact, 0.0);
    EXPECT_DOUBLE_EQ(row(third, 100)->averageEnergyImpact, 63.0 * 2 / 8);
}

TEST(Sampler, ThreadsAreReadInTurnsOfFive)
{
    Fixture f;
    for (int pid = 1000; pid < 1010; ++pid) {
        f.process(pid, "t", kMe, 1, 1, nul({"t"}), "/");
        f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(pid) + "/status", Fixture::statusText("t", kMe, 1, 0, 100));
        f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(pid + 50000) + "/status", Fixture::statusText("t", kMe, 1, 0, 100));
    }
    Options o = options(f);
    o.threadTurns = 5;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadThreads;
    const Snapshot first = s.sample(reads, 0.0);
    EXPECT_EQ(first.counters.threadStatusReads, 20u); // every new process at once (two threads each)
    std::vector<int> readAt(10, -1);
    Snapshot snap;
    for (int i = 1; i <= 6; ++i) {
        for (int pid = 1000; pid < 1010; ++pid) // +100 voluntary switches per thread and second
            for (int t : {pid, pid + 50000})
                f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(t) + "/status", Fixture::statusText("t", kMe, 1, 0, 100 + 100 * i));
        snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.threadStatusReads, 4u) << i; // a fifth of the ten processes, two threads each
        for (const ProcessRow &r : snap.rows) {
            if (r.wakeRate >= 0 && readAt[r.pid - 1000] < 0)
                readAt[r.pid - 1000] = i;
        }
    }
    for (int pid = 1000; pid < 1010; ++pid) { // every process covered within five samples (A-S9)
        EXPECT_GE(readAt[pid - 1000], 1) << pid;
        EXPECT_LE(readAt[pid - 1000], 5) << pid;
    }
    // Two threads, +100 each per second: 200 switches a second, whatever the length of the process's turn.
    for (const ProcessRow &r : snap.rows)
        EXPECT_NEAR(r.wakeRate, 200.0, 1e-9) << r.pid;
}

TEST(Sampler, DescriptorsAreReadInTurnsOfTenAndClassified)
{
    Fixture f;
    for (int pid = 2000; pid < 2010; ++pid) {
        f.process(pid, "d", kMe, 1, 1, nul({"d"}), "/");
        const std::string fd = "proc/" + std::to_string(pid) + "/fd/";
        f.link("socket:[" + std::to_string(700000 + pid) + "]", fd + "3");
        f.link("/dev/dri/renderD128", fd + "4");
        f.link("/etc/hosts", fd + "5");
    }
    Options o = options(f);
    o.descriptorTurns = 10;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors;
    const Snapshot first = s.sample(reads, 0.0);
    EXPECT_EQ(first.counters.fdListReads, 10u);
    EXPECT_EQ(first.counters.fdLinks, 30u);
    for (const ProcessRow &r : first.rows)
        EXPECT_EQ(r.openFiles, 3);
    for (int i = 1; i < 10; ++i) {
        const Snapshot snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.fdListReads, 1u) << i; // one tenth of the ten processes
        EXPECT_EQ(snap.counters.cgroupReads, 1u) << i; // its unit read again in its turn
    }
}

TEST(Sampler, GpuSharesPerProcessAndPerDevice)
{
    Fixture f;
    auto client = [&](int pid, int fd, int clientId, unsigned long long render, unsigned long long video) {
        f.write("proc/" + std::to_string(pid) + "/fdinfo/" + std::to_string(fd),
                "pos:\t0\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t" + std::to_string(clientId)
                    + "\ndrm-engine-render:\t" + std::to_string(render) + " ns\ndrm-engine-video:\t" + std::to_string(video)
                    + " ns\ndrm-engine-capacity-video:\t2\ndrm-memory-system0:\t4 MiB\n");
    };
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    f.process(200, "Hyprland", kMe, 1, 1, nul({"Hyprland"}), user + "/session.slice/wayland-wm@hyprland.desktop.service");
    f.link("/dev/dri/renderD128", "proc/100/fd/7");
    f.link("/dev/dri/renderD128", "proc/100/fd/8"); // the same client through a second descriptor: counted once
    f.link("/dev/dri/card1", "proc/200/fd/9");
    client(100, 7, 1, 0, 0);
    client(100, 8, 1, 0, 0);
    client(200, 9, 2, 0, 0);
    Options o = options(f);
    o.descriptorTurns = 1;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors | ReadGpu;
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_LT(row(first, 100)->gpuPercent, 0); // no rate yet
    client(100, 7, 1, 500000000, 1000000000); // render 0.5 s in 1 s: 50 %; video 1 s on a capacity of 2: 50 %
    client(100, 8, 1, 500000000, 1000000000);
    client(200, 9, 2, 300000000, 0);
    const Snapshot snap = s.sample(reads, 2.0);
    const ProcessRow *game = row(snap, 100);
    ASSERT_TRUE(game->hasGpu);
    EXPECT_DOUBLE_EQ(game->gpuPercent, 50.0); // the busiest engine (AM46)
    EXPECT_EQ(game->gpuNs, 1500000000u);       // every engine's time
    EXPECT_DOUBLE_EQ(row(snap, 200)->gpuPercent, 30.0);
    ASSERT_EQ(snap.gpus.size(), 1u);
    const GpuDevice &gpu = snap.gpus[0];
    EXPECT_EQ(gpu.pdev, "0000:00:02.0");
    EXPECT_EQ(gpu.driver, "i915");
    double render = -1, video = -1;
    for (const GpuEngine &e : gpu.engines) {
        if (e.name == "render")
            render = e.percent;
        if (e.name == "video")
            video = e.percent;
    }
    EXPECT_DOUBLE_EQ(render, 80.0); // the two clients summed (AM47)
    EXPECT_DOUBLE_EQ(video, 50.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 3u);
}

TEST(Sampler, UserAndSystemAsMacOSMeansThem)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    f.process(200, "theirs", 1001, 100, 1, nul({"theirs"}), "/");
    f.write("proc/stat", "cpu  1000 0 1000 8000 0 0 0 0 0 0\ncpu0 1000 0 1000 8000 0 0 0 0 0 0\n");
    f.write("proc/loadavg", "0.10 0.20 0.30 1/321 999\n");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadSystemCpu;
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_EQ(first.system.tasks, 321);
    EXPECT_LT(first.system.userShare, 0);
    // 1000 ticks pass: 400 busy (300 user mode, 100 kernel mode), 600 idle; the user's process used 100, another's 250.
    f.write("proc/stat", "cpu  1300 0 1100 8600 0 0 0 0 0 0\ncpu0 1300 0 1100 8600 0 0 0 0 0 0\n");
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 200, 0, 1, 1));
    f.write("proc/200/stat", Fixture::statLine(200, "theirs", 'S', 1, 0, 350, 0, 1, 1));
    const Snapshot snap = s.sample(reads, 11.0);
    ASSERT_TRUE(snap.system.sharesByOwner);
    EXPECT_DOUBLE_EQ(snap.system.userShare, 0.1);   // the user's processes (AD5)
    EXPECT_DOUBLE_EQ(snap.system.systemShare, 0.3); // everything else that was busy
    EXPECT_DOUBLE_EQ(snap.system.idleShare, 0.6);
    ASSERT_EQ(snap.system.perCpuBusy.size(), 1u);
    EXPECT_DOUBLE_EQ(snap.system.perCpuBusy[0], 0.4);

    // Without the processes (the Dock's graph while the window is hidden), the kernel's split stays.
    f.write("proc/stat", "cpu  1600 0 1200 9200 0 0 0 0 0 0\ncpu0 1600 0 1200 9200 0 0 0 0 0 0\n");
    const Snapshot hidden = s.sample(ReadSystemCpu, 21.0);
    EXPECT_FALSE(hidden.system.sharesByOwner);
    EXPECT_DOUBLE_EQ(hidden.system.userShare, 0.3);
    EXPECT_DOUBLE_EQ(hidden.system.systemShare, 0.1);
    EXPECT_TRUE(hidden.rows.empty());
    EXPECT_EQ(hidden.counters.statReads, 0u);
}

TEST(Sampler, WholePhysicalDisksAndInterfacesButLo)
{
    Fixture f;
    f.link("../../devices/pci0000:00/nvme0", "sys/block/nvme0n1/device"); // a link, as sysfs has it (dangling here)
    f.write("sys/block/loop0/size", "0\n"); // no device link: not counted (AM42)
    f.write("proc/diskstats", " 259 0 nvme0n1 100 0 2000 50 200 0 4000 100 0 300 150 0 0 0 0\n"
                              " 259 1 nvme0n1p1 100 0 2000 50 200 0 4000 100 0 300 150 0 0 0 0\n"
                              "   7 0 loop0 999 0 999 0 0 0 0 0 0 0 0 0 0 0 0\n");
    f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n    lo: 500 5 0 0 0 0 0 0 500 5 0 0 0 0 0 0\n"
                            " wlan0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n");
    Sampler s(options(f));
    const unsigned reads = ReadSystemDisk | ReadSystemNet;
    s.sample(reads, 1.0);
    f.write("proc/diskstats", " 259 0 nvme0n1 300 0 6000 150 400 0 8000 300 0 1300 450 0 0 0 0\n"
                              " 259 1 nvme0n1p1 300 0 6000 150 400 0 8000 300 0 1300 450 0 0 0 0\n"
                              "   7 0 loop0 999 0 999 0 0 0 0 0 0 0 0 0 0 0 0\n");
    f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n    lo: 900 9 0 0 0 0 0 0 900 9 0 0 0 0 0 0\n"
                            " wlan0: 3000 30 0 0 0 0 0 0 2500 25 0 0 0 0 0 0\n");
    const Snapshot snap = s.sample(reads, 3.0);
    ASSERT_EQ(snap.system.disks.size(), 1u);
    const DiskSnapshot &d = snap.system.disks[0];
    EXPECT_EQ(d.name, "nvme0n1");
    EXPECT_EQ(d.reads, 300u);
    EXPECT_EQ(d.bytesRead, 6000u * 512);
    EXPECT_DOUBLE_EQ(d.readsPerSec, 100.0);
    EXPECT_DOUBLE_EQ(d.writesPerSec, 100.0);
    EXPECT_DOUBLE_EQ(d.readBytesPerSec, 2000.0 * 512);
    EXPECT_DOUBLE_EQ(d.activeTime, 0.5);   // 1000 ms of I/O in 2 s
    EXPECT_DOUBLE_EQ(d.responseMs, 300.0 / 400.0); // (100 + 200) ms over 400 requests
    EXPECT_EQ(snap.system.diskTotal.reads, 300u);
    ASSERT_EQ(snap.system.interfaces.size(), 1u);
    EXPECT_EQ(snap.system.interfaces[0].name, "wlan0");
    EXPECT_EQ(snap.system.netTotal.packetsIn, 30u);
    EXPECT_DOUBLE_EQ(snap.system.netTotal.bytesInPerSec, 1000.0);
    EXPECT_DOUBLE_EQ(snap.system.netTotal.packetsOutPerSec, 2.5);
}

TEST(Sampler, AWindowOwnerIsAnApp)
{
    Fixture f;
    f.process(100, "zed", kMe, 1, 1, nul({"zed"}), user + "/app.slice/zed.service");
    Sampler s(options(f));
    EXPECT_EQ(s.sample(ReadProcesses | ReadStatus, 1.0).rows[0].kind, Kind::Background);
    s.setWindowOwners({100});
    EXPECT_EQ(s.sample(ReadProcesses | ReadStatus, 2.0).rows[0].kind, Kind::App);
}

TEST(Sampler, TheRealProcIsReadable)
{
    // This test's own process, through the real /proc: its row, its owner, a sane CPU share.
    Options o = defaultOptions();
    Sampler s(o);
    s.sample(ReadProcesses | ReadStatus | ReadIo | ReadSystemCpu | ReadSystemMemory);
    volatile double x = 0;
    for (int i = 0; i < 2000000; ++i)
        x += i * 0.5;
    EXPECT_GT(x, 0.0);
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadIo | ReadSystemCpu | ReadSystemMemory);
    const ProcessRow *me = row(snap, getpid());
    ASSERT_NE(me, nullptr);
    EXPECT_TRUE(me->own);
    EXPECT_TRUE(me->hasMemory);
    EXPECT_GT(me->realMemory, 0u);
    EXPECT_TRUE(me->hasIo);
    EXPECT_GE(me->cpuPercent, 0.0);
    EXPECT_TRUE(snap.system.memory.ok);
    EXPECT_GT(snap.system.processes, 0);
    EXPECT_GE(snap.cpuMs, 0.0);
}
