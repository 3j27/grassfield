// The /proc and /sys parsers of the activity monitor (apps/activity/src/procparse.cpp; ADR-0038 b, docs/specs/activity.md
// AM20 to AM49): every field the monitor shows, short and hostile texts, the drm-usage-stats keys.
#include "procparse.h"

#include <gtest/gtest.h>

using namespace activity;

TEST(ProcParse, StatWithAHostileShortName)
{
    // A short name may hold spaces and parentheses: it runs to the last ")".
    const std::string text = "4242 (a) b (c) R 1 4242 4242 0 -1 4194304 77 0 3 0 1200 300 0 0 20 -5 9 0 98765 104857600 2560 0\n";
    StatFields st;
    ASSERT_TRUE(parseStat(text, st));
    EXPECT_EQ(st.pid, 4242);
    EXPECT_EQ(st.comm, "a) b (c");
    EXPECT_EQ(st.state, 'R');
    EXPECT_EQ(st.ppid, 1);
    EXPECT_EQ(st.flags, 4194304u);
    EXPECT_EQ(st.minflt, 77u);
    EXPECT_EQ(st.majflt, 3u);
    EXPECT_EQ(st.utime, 1200u);
    EXPECT_EQ(st.stime, 300u);
    EXPECT_EQ(st.nice, -5);
    EXPECT_EQ(st.numThreads, 9);
    EXPECT_EQ(st.starttime, 98765u);
    EXPECT_EQ(st.vsize, 104857600u);
    EXPECT_EQ(st.rssPages, 2560);
}

TEST(ProcParse, StatRefusesTruncatedOrBrokenText)
{
    StatFields st;
    EXPECT_FALSE(parseStat("", st));
    EXPECT_FALSE(parseStat("12 (x", st));
    EXPECT_FALSE(parseStat("12 (x) S 1 2 3", st));
    EXPECT_FALSE(parseStat("abc (x) S 1 2 3 0 -1 0 0 0 0 0 1 1 0 0 20 0 1 0 5 1 1 0", st));
}

TEST(ProcParse, KernelThreadFlag)
{
    StatFields st;
    ASSERT_TRUE(parseStat("2 (kthreadd) S 0 0 0 0 -1 2129984 0 0 0 0 0 1 0 0 20 0 1 0 10 0 0 0", st));
    EXPECT_NE(st.flags & kPfKthread, 0u);
}

TEST(ProcParse, Status)
{
    const std::string text = "Name:\tfirefox\nUmask:\t0022\nPPid:\t900\nUid:\t1000\t1001\t1000\t1000\n"
                             "VmHWM:\t  900000 kB\nVmRSS:\t  800000 kB\nRssAnon:\t  600000 kB\nRssFile:\t  150000 kB\n"
                             "RssShmem:\t   50000 kB\nVmSize:\t 4000000 kB\nVmSwap:\t   12000 kB\n"
                             "voluntary_ctxt_switches:\t5000\nnonvoluntary_ctxt_switches:\t70\n";
    StatusFields st;
    ASSERT_TRUE(parseStatus(text, st));
    EXPECT_EQ(st.name, "firefox");
    EXPECT_TRUE(st.hasUid);
    EXPECT_EQ(st.ruid, 1000u);
    EXPECT_EQ(st.euid, 1001u);
    EXPECT_EQ(st.ppid, 900);
    EXPECT_TRUE(st.hasMemory);
    EXPECT_EQ(st.vmRssKb, 800000u);
    EXPECT_EQ(st.rssAnonKb, 600000u);
    EXPECT_EQ(st.rssFileKb, 150000u);
    EXPECT_EQ(st.rssShmemKb, 50000u);
    EXPECT_EQ(st.vmSwapKb, 12000u);
    EXPECT_EQ(st.vmHwmKb, 900000u);
    EXPECT_EQ(st.vmSizeKb, 4000000u);
    EXPECT_TRUE(st.hasCtx);
    EXPECT_EQ(st.voluntaryCtx, 5000u);
    EXPECT_EQ(st.involuntaryCtx, 70u);
}

TEST(ProcParse, StatusOfAKernelThreadHasNoMemory)
{
    StatusFields st;
    ASSERT_TRUE(parseStatus("Name:\tkworker/0:1\nUid:\t0\t0\t0\t0\nvoluntary_ctxt_switches:\t1\n", st));
    EXPECT_FALSE(st.hasMemory);
}

TEST(ProcParse, Io)
{
    IoFields io;
    ASSERT_TRUE(parseIo("rchar: 100\nwchar: 200\nsyscr: 3\nsyscw: 4\nread_bytes: 4096\nwrite_bytes: 8192\ncancelled_write_bytes: 0\n", io));
    EXPECT_EQ(io.readBytes, 4096u);
    EXPECT_EQ(io.writeBytes, 8192u);
    EXPECT_EQ(io.syscr, 3u);
    EXPECT_EQ(io.syscw, 4u);
    EXPECT_FALSE(parseIo("rchar: 100\n", io));
}

TEST(ProcParse, CgroupV2AndCmdline)
{
    EXPECT_EQ(parseCgroupV2("0::/user.slice/user-1000.slice/user@1000.service/app.slice/x.service\n"),
              "/user.slice/user-1000.slice/user@1000.service/app.slice/x.service");
    EXPECT_EQ(parseCgroupV2("12:cpu:/x\n"), "");
    const std::string raw("/usr/lib/firefox/firefox\0-contentproc\0-childID\0", 47);
    EXPECT_EQ(cmdlineFirstWord(raw), "/usr/lib/firefox/firefox");
    EXPECT_EQ(cmdlineJoined(raw), "/usr/lib/firefox/firefox -contentproc -childID");
    EXPECT_EQ(baseName("/usr/lib/firefox/firefox"), "firefox");
    EXPECT_EQ(baseName("sshd: bob@pts/0"), "0"); // why another owner's name never comes from argv[0] (AD25)
    EXPECT_EQ(baseName("plain"), "plain");
}

TEST(ProcParse, ProcStatAndLoadavg)
{
    const std::string text = "cpu  100 5 50 1000 20 3 2 1 0 0\ncpu0 50 2 25 500 10 1 1 0 0 0\ncpu1 50 3 25 500 10 2 1 1 0 0\n"
                             "intr 1 2 3\nctxt 999\n";
    CpuTimes total;
    std::vector<CpuTimes> per;
    ASSERT_TRUE(parseProcStat(text, total, per));
    EXPECT_EQ(total.user, 100u);
    EXPECT_EQ(total.idleAll(), 1020u);
    EXPECT_EQ(total.busy(), 161u);
    ASSERT_EQ(per.size(), 2u);
    EXPECT_EQ(per[1].steal, 1u);
    EXPECT_EQ(parseLoadavgTasks("0.52 0.40 0.31 2/1734 98765\n"), 1734);
    EXPECT_EQ(parseLoadavgTasks("garbage"), -1);
}

TEST(ProcParse, MeminfoPressureSwapsZram)
{
    Meminfo m;
    ASSERT_TRUE(parseMeminfo("MemTotal:       32000000 kB\nMemFree:  1000 kB\nMemAvailable:   16000000 kB\nBuffers: 100 kB\n"
                             "Cached:  5000 kB\nActive(file):   3000000 kB\nInactive(file): 2000000 kB\nShmem: 70 kB\n"
                             "SUnreclaim: 400000 kB\nKernelStack: 30000 kB\nPageTables: 70000 kB\nUnevictable: 500 kB\n"
                             "SwapTotal: 8000000 kB\nSwapFree: 7000000 kB\nCommitLimit: 24000000 kB\nCommitted_AS: 20000000 kB\n",
                             m));
    EXPECT_EQ(m.memTotal, 32000000u);
    EXPECT_EQ(m.memAvailable, 16000000u);
    EXPECT_EQ(m.activeFile, 3000000u);
    EXPECT_EQ(m.inactiveFile, 2000000u);
    EXPECT_EQ(m.committedAs, 20000000u);
    Meminfo none;
    EXPECT_FALSE(parseMeminfo("MemTotal: 1 kB\n", none));

    Pressure p;
    ASSERT_TRUE(parsePressure("some avg10=12.50 avg60=3.00 avg300=1.00 total=100\nfull avg10=6.25 avg60=0.00 avg300=0.00 total=5\n", p));
    EXPECT_DOUBLE_EQ(p.someAvg10, 12.5);
    EXPECT_DOUBLE_EQ(p.fullAvg10, 6.25);

    const auto swaps = parseSwaps("Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/zram0  partition\t32000000\t1000000\t100\n"
                                  "/swap/swapfile  file\t8000000\t200\t0\n");
    ASSERT_EQ(swaps.size(), 2u);
    EXPECT_TRUE(swaps[0].zram());
    EXPECT_FALSE(swaps[1].zram());
    EXPECT_EQ(swaps[1].usedKb, 200u);

    uint64_t used = 0;
    ASSERT_TRUE(parseZramMemUsed("  4096000  1365333  1400000        0  1400000      123        0        0        0\n", used));
    EXPECT_EQ(used, 1400000u);
}

TEST(ProcParse, DiskstatsAndNetDev)
{
    const auto disks = parseDiskstats(" 259       0 nvme0n1 1000 10 80000 500 2000 20 160000 900 0 1200 1400 0 0 0 0 0 0\n"
                                      "   7       0 loop0 1 0 2 0 0 0 0 0 0 0 0 0 0 0 0\n");
    ASSERT_EQ(disks.size(), 2u);
    EXPECT_EQ(disks[0].name, "nvme0n1");
    EXPECT_EQ(disks[0].reads, 1000u);
    EXPECT_EQ(disks[0].sectorsRead, 80000u);
    EXPECT_EQ(disks[0].readTicksMs, 500u);
    EXPECT_EQ(disks[0].writes, 2000u);
    EXPECT_EQ(disks[0].sectorsWritten, 160000u);
    EXPECT_EQ(disks[0].writeTicksMs, 900u);
    EXPECT_EQ(disks[0].ioTicksMs, 1200u);

    const auto net = parseNetDev("Inter-|   Receive                                                |  Transmit\n"
                                 " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
                                 "    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0\n"
                                 "wlan0: 50000 40 0 0 0 0 0 0 7000 30 0 0 0 0 0 0\n");
    ASSERT_EQ(net.size(), 2u);
    EXPECT_EQ(net[1].name, "wlan0");
    EXPECT_EQ(net[1].rxBytes, 50000u);
    EXPECT_EQ(net[1].rxPackets, 40u);
    EXPECT_EQ(net[1].txBytes, 7000u);
    EXPECT_EQ(net[1].txPackets, 30u);
}

TEST(ProcParse, DrmFdinfo)
{
    const std::string text = "pos:\t0\nflags:\t02100002\nmnt_id:\t26\nino:\t1031\ndrm-driver:\ti915\ndrm-client-id:\t42\n"
                             "drm-pdev:\t0000:00:02.0\ndrm-total-system0:\t12 MiB\ndrm-memory-local0:\t8 KiB\n"
                             "drm-engine-render:\t25000000 ns\ndrm-engine-video:\t3000 ns\ndrm-engine-capacity-video:\t2\n";
    DrmClient c;
    ASSERT_TRUE(parseDrmFdinfo(text, c));
    EXPECT_EQ(c.driver, "i915");
    EXPECT_EQ(c.pdev, "0000:00:02.0");
    EXPECT_EQ(c.clientId, 42u);
    EXPECT_EQ(c.engineNs.at("render"), 25000000u);
    EXPECT_EQ(c.engineNs.at("video"), 3000u);
    EXPECT_EQ(c.engineNs.count("capacity-video"), 0u);
    EXPECT_EQ(c.engineCapacity.at("video"), 2u);
    EXPECT_EQ(c.memoryBytes.at("system0"), 12u * 1024 * 1024);
    EXPECT_EQ(c.memoryBytes.at("local0"), 8u * 1024);
    DrmClient none;
    EXPECT_FALSE(parseDrmFdinfo("pos:\t0\nflags:\t0\n", none));
}

TEST(ProcParse, ProcessNames)
{
    // AM17 after the review of 949fc98: argv[0] names the process only when it is the executable or the invoked name.
    EXPECT_EQ(processName("/usr/bin/foot", "foot", "/usr/bin/foot"), "foot");
    EXPECT_EQ(processName("/usr/lib/fakechrome/chrome --type=renderer --user-data-dir=/home/u/.config/myapp --lang=en-US",
                          "chrome", "/usr/lib/fakechrome/chrome"),
              "chrome");                                                              // a title over argv[0]
    EXPECT_EQ(processName("sshd: alice@pts/0", "sshd", "/usr/bin/sshd"), "sshd");    // setproctitle
    EXPECT_EQ(processName("-bash", "bash", "/usr/bin/bash"), "bash");                // a login shell
    EXPECT_EQ(processName("vi", "vi", "/usr/bin/vim"), "vi");                         // a symbolic link: the invoked name
    EXPECT_EQ(processName("/usr/bin/gnome-session-binary", "gnome-session-b", ""), "gnome-session-binary"); // comm cut at 15
    EXPECT_EQ(processName("/usr/bin/gnome-session-other", "gnome-session-b", "/usr/bin/x"), "x"); // not the invoked name
    EXPECT_EQ(processName("/usr/bin/gnome-session-binary --session=gnome", "gnome-session-b", ""), "gnome-session-b"); // a title that starts as the cut name
    EXPECT_EQ(processName("worker", "kworkerish", "/opt/app/app"), "app");           // neither: the executable
    EXPECT_EQ(processName("/opt/old/app", "app", "/opt/old/app (deleted)"), "app");   // replaced on disk
    EXPECT_EQ(processName("title with spaces", "comm", ""), "comm");                 // nothing else: stat's name
    EXPECT_EQ(processName("", "comm", ""), "comm");
}

TEST(ProcParse, Statm)
{
    Statm m;
    ASSERT_TRUE(parseStatm("50000 2000 750 10 0 900 0\n", m));
    EXPECT_EQ(m.size, 50000u);
    EXPECT_EQ(m.resident, 2000u);
    EXPECT_EQ(m.shared, 750u);
    EXPECT_FALSE(parseStatm("50000 x 750", m));
    EXPECT_FALSE(parseStatm("", m));
}

TEST(ProcParse, StatCodeAddressesOnlyWhenAsked)
{
    const std::string line = "42 (app) S 1 42 42 0 -1 4194304 10 0 2 0 7 3 0 0 20 0 1 0 5000 104857600 2560 "
                             "18446744073709551615 93824992231424 93824992310000 140737488347136 0 0\n";
    StatFields all, some;
    ASSERT_TRUE(parseStat(line, all));
    EXPECT_EQ(all.startCode, 93824992231424u);
    EXPECT_EQ(all.endCode, 93824992310000u);
    EXPECT_EQ(all.rssPages, 2560);
    ASSERT_TRUE(parseStat(line, some, false)); // another owner's: never traceable, the fields are 0 anyway
    EXPECT_EQ(some.startCode, 0u);
    EXPECT_EQ(some.starttime, 5000u);
    EXPECT_EQ(some.rssPages, 2560);
}
