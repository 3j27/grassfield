// A-S15 (docs/specs/activity.md AM66; step 4): the Performance window's facts on fixture trees: the processors (model,
// sockets, cores, logical processors, caches counted once, base and current speed), the uptime, a disk (capacity, SSD or
// HDD, model), an interface's kind and a Wi-Fi signal.
#include "fixture.h"
#include "machine.h"

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

// One logical processor: its core on its package, its two caches (L1 its own, L3 shared by all), its speeds.
void cpu(const Fixture &f, int n, int core, const char *l3Shared)
{
    const std::string dir = "sys/devices/system/cpu/cpu" + std::to_string(n) + "/";
    f.write(dir + "topology/core_id", std::to_string(core) + "\n");
    f.write(dir + "topology/physical_package_id", "0\n");
    f.write(dir + "cache/index0/level", "1\n");
    f.write(dir + "cache/index0/type", "Data\n");
    f.write(dir + "cache/index0/size", "48K\n");
    f.write(dir + "cache/index0/shared_cpu_list", std::to_string(n) + "\n");
    f.write(dir + "cache/index1/level", "3\n");
    f.write(dir + "cache/index1/type", "Unified\n");
    f.write(dir + "cache/index1/size", "12288K\n");
    f.write(dir + "cache/index1/shared_cpu_list", std::string(l3Shared) + "\n");
    f.write(dir + "cpufreq/scaling_cur_freq", std::to_string(1000000 + n * 1000000) + "\n");
}

} // namespace

TEST(Machine, TheProcessors)
{
    Fixture f;
    f.write("proc/cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel(R) Core(TM) i5 CPU @ 2.40GHz\n\nprocessor\t: 1\n");
    // Two cores of two threads each: cpu0 and cpu2 on core 0, cpu1 and cpu3 on core 1.
    cpu(f, 0, 0, "0-3");
    cpu(f, 1, 1, "0-3");
    cpu(f, 2, 0, "0-3");
    cpu(f, 3, 1, "0-3");
    f.write("sys/devices/system/cpu/cpu0/cpufreq/base_frequency", "2400000\n");
    f.write("sys/devices/system/cpu/online", "0-3\n"); // a file, not a cpuN directory
    f.write("sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq", "9\n"); // not a processor
    const CpuFacts facts = readCpuFacts(f.sys(), f.proc());
    EXPECT_EQ(facts.model, "Intel(R) Core(TM) i5 CPU @ 2.40GHz");
    EXPECT_EQ(facts.sockets, 1);
    EXPECT_EQ(facts.cores, 2);
    EXPECT_EQ(facts.logical, 4);
    EXPECT_EQ(facts.l1, 4u * 48 * 1024);       // one per logical processor here
    EXPECT_EQ(facts.l3, 12288u * 1024);        // shared: once
    EXPECT_EQ(facts.l2, 0u);
    EXPECT_DOUBLE_EQ(facts.baseGhz, 2.4);
    EXPECT_DOUBLE_EQ(meanCurrentGhz(f.sys()), 2.5); // 1, 2, 3 and 4 GHz
    EXPECT_EQ(parseCacheSize("32M\n"), 32u * 1024 * 1024);
    EXPECT_EQ(parseCacheSize("512"), 512u);
    EXPECT_EQ(parseCacheSize("K"), 0u);
    EXPECT_EQ(parseCacheSize("-1K"), 0u);
    // A machine without cpufreq or cpuinfo: nothing made up.
    Fixture bare;
    bare.write("sys/devices/system/cpu/cpu0/topology/core_id", "0\n");
    const CpuFacts none = readCpuFacts(bare.sys(), bare.proc());
    EXPECT_EQ(none.model, "");
    EXPECT_EQ(none.logical, 1);
    EXPECT_LT(none.baseGhz, 0);
    EXPECT_LT(meanCurrentGhz(bare.sys()), 0);
}

TEST(Machine, UptimeDisksAndInterfaces)
{
    Fixture f;
    f.write("proc/uptime", "350735.47 234388.90\n");
    EXPECT_DOUBLE_EQ(readUptime(f.proc()), 350735.47);
    EXPECT_LT(readUptime(f.sys()), 0);

    f.write("sys/block/nvme0n1/size", "1000215216\n");
    f.write("sys/block/nvme0n1/queue/rotational", "0\n");
    f.write("sys/block/nvme0n1/device/model", "Samsung SSD 980 PRO 500GB                \n");
    f.write("sys/block/sda/size", "1953525168\n");
    f.write("sys/block/sda/queue/rotational", "1\n");
    const DiskFacts nvme = readDiskFacts(f.sys(), "nvme0n1");
    EXPECT_EQ(nvme.capacity, 1000215216ull * 512);
    EXPECT_EQ(nvme.rotational, 0);
    EXPECT_EQ(nvme.model, "Samsung SSD 980 PRO 500GB");
    const DiskFacts sda = readDiskFacts(f.sys(), "sda");
    EXPECT_EQ(sda.rotational, 1);
    EXPECT_EQ(sda.model, "");
    EXPECT_EQ(readDiskFacts(f.sys(), "../nvme0n1").capacity, 0u);

    f.write("sys/class/net/wlan0/wireless/.keep", "");
    f.write("sys/class/net/wlan0/type", "1\n");
    f.write("sys/class/net/enp3s0/type", "1\n");
    f.write("sys/class/net/br0/type", "1\n");
    f.write("sys/class/net/br0/bridge/.keep", "");
    f.write("sys/class/net/tun0/type", "65534\n");
    EXPECT_EQ(netKind(f.sys(), "wlan0"), "wifi");
    EXPECT_EQ(netKind(f.sys(), "enp3s0"), "ethernet");
    EXPECT_EQ(netKind(f.sys(), "br0"), "");
    EXPECT_EQ(netKind(f.sys(), "tun0"), "");
    EXPECT_EQ(netKind(f.sys(), "../wlan0"), "");

    const char *wireless = "Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n"
                           " face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n"
                           "wlan0: 0000   58.  -52.  -256        0      0      0      0     47        0\n";
    EXPECT_EQ(wirelessSignal(wireless, "wlan0"), -52);
    EXPECT_EQ(wirelessSignal(wireless, "wlan1"), 0);
    EXPECT_EQ(wirelessSignal(wireless, "wlan"), 0);
}
