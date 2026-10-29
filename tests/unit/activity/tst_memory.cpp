// The Memory tab's summary and pressure (apps/activity/src/sampler.cpp; ADR-0038 AD7, AD8; docs/specs/activity.md AM32 to
// AM34, acceptance A-S3): the level at each threshold, App + Wired + Compressed = Memory Used, zram as Compressed and the
// disk swap as Swap Used, the column's name.
#include "fixture.h"
#include "sampler.h"

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

Meminfo mem(uint64_t total, uint64_t available)
{
    Meminfo m;
    m.ok = true;
    m.memTotal = total;
    m.memAvailable = available;
    return m;
}

Pressure psi(double some, double full)
{
    Pressure p;
    p.ok = true;
    p.someAvg10 = some;
    p.fullAvg10 = full;
    return p;
}

void writeMeminfo(const Fixture &f, uint64_t availableKb)
{
    f.write("proc/meminfo", "MemTotal:       16000000 kB\nMemAvailable:   " + std::to_string(availableKb) + " kB\n"
                            "Active(file):    2000000 kB\nInactive(file):  1000000 kB\nSUnreclaim:       300000 kB\n"
                            "KernelStack:       20000 kB\nPageTables:        60000 kB\nUnevictable:       20000 kB\n"
                            "Shmem: 1 kB\nCommitLimit: 20000000 kB\nCommitted_AS: 12000000 kB\n");
}

} // namespace

TEST(Memory, PressureLevelAtEachThreshold)
{
    // AM33: red when full avg10 >= 5 or less than 5 % left; yellow when some avg10 >= 10 or less than 15 % left.
    EXPECT_EQ(pressureLevel(mem(1000, 500), psi(0, 0)), PressureLevel::Normal);
    EXPECT_EQ(pressureLevel(mem(1000, 500), psi(9.99, 4.99)), PressureLevel::Normal);
    EXPECT_EQ(pressureLevel(mem(1000, 500), psi(10.0, 0)), PressureLevel::Warning);
    EXPECT_EQ(pressureLevel(mem(1000, 500), psi(10.0, 5.0)), PressureLevel::Critical);
    EXPECT_EQ(pressureLevel(mem(1000, 150), psi(0, 0)), PressureLevel::Normal);
    EXPECT_EQ(pressureLevel(mem(1000, 149), psi(0, 0)), PressureLevel::Warning);
    EXPECT_EQ(pressureLevel(mem(1000, 50), psi(0, 0)), PressureLevel::Warning); // exactly 5 % left: not yet critical
    EXPECT_EQ(pressureLevel(mem(1000, 49), psi(0, 0)), PressureLevel::Critical);
    // Without /proc/pressure the memory left decides alone (AM78).
    Pressure none;
    EXPECT_EQ(pressureLevel(mem(1000, 500), none), PressureLevel::Normal);
    EXPECT_EQ(pressureLevel(mem(1000, 100), none), PressureLevel::Warning);
    EXPECT_EQ(pressureLevel(mem(1000, 10), none), PressureLevel::Critical);
}

TEST(Memory, SummaryAddsUpAndNamesZramCompressed)
{
    Fixture f;
    writeMeminfo(f, 6000000);
    f.write("proc/pressure/memory", "some avg10=12.00 avg60=1.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n");
    f.write("proc/swaps", "Filename Type Size Used Priority\n/dev/zram0 partition 16000000 900000 100\n");
    f.write("sys/block/zram0/mm_stat", "900000000 300000000 314572800 0 314572800 0 0 0 0\n");
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    Sampler s(o);
    const Snapshot snap = s.sample(ReadSystemMemory, 10.0);
    const MemorySummary &m = snap.system.memory;
    ASSERT_TRUE(m.ok);
    EXPECT_EQ(m.physical, 16000000ull * 1024);
    EXPECT_EQ(m.used, 10000000ull * 1024);
    EXPECT_EQ(m.compressed, 314572800ull);
    EXPECT_EQ(m.wired, (300000ull + 20000 + 60000 + 20000) * 1024);
    EXPECT_EQ(m.app + m.wired + m.compressed, m.used); // AD7: the three add up, as on macOS
    EXPECT_EQ(m.cached, 3000000ull * 1024);
    EXPECT_EQ(m.swapUsed, 0u); // zram is Compressed, not Swap Used
    EXPECT_TRUE(m.swapIsZramOnly);
    EXPECT_DOUBLE_EQ(m.inUse, 10.0 / 16.0);
    EXPECT_TRUE(m.hasPressure);
    EXPECT_EQ(m.level, PressureLevel::Warning);
    EXPECT_EQ(m.committed, 12000000ull * 1024);
}

TEST(Memory, DiskSwapIsSwapUsedAndRenamesTheColumn)
{
    Fixture f;
    writeMeminfo(f, 15500000);
    f.write("proc/swaps", "Filename Type Size Used Priority\n/dev/zram0 partition 16000000 100 100\n/swap/swapfile file 8000000 4096 0\n");
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    Sampler s(o);
    const MemorySummary m = s.sample(ReadSystemMemory, 1.0).system.memory;
    ASSERT_TRUE(m.ok);
    EXPECT_EQ(m.swapUsed, 4096ull * 1024);
    EXPECT_FALSE(m.swapIsZramOnly); // AM34: the column becomes "Swapped Memory"
    EXPECT_EQ(m.compressed, 0u);    // no zram device in /sys/block
    EXPECT_FALSE(m.hasPressure);    // no /proc/pressure/memory in this tree (AM78)
    EXPECT_EQ(m.level, PressureLevel::Normal);
}

TEST(Memory, AppNeverBelowZero)
{
    Fixture f;
    f.write("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 990 kB\nSUnreclaim: 500 kB\n");
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    Sampler s(o);
    const MemorySummary m = s.sample(ReadSystemMemory, 1.0).system.memory;
    ASSERT_TRUE(m.ok);
    EXPECT_EQ(m.used, 10u * 1024);
    EXPECT_EQ(m.app, 0u);
}
