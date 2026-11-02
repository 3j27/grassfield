// The Performance window's facts about the machine (spec AM66; ADR-0038 g): read from /proc and /sys when the window asks,
// never at each sample but the processors' speed. Plain C++ and POSIX, fixture-tested (tests/unit/activity/tst_machine.cpp).
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace activity
{

struct CpuFacts {
    std::string model;     // /proc/cpuinfo's first "model name" ("" when it has none)
    int sockets = 0;       // distinct physical_package_id
    int cores = 0;         // distinct (package, core_id)
    int logical = 0;       // cpuN with a topology
    double baseGhz = -1;   // cpufreq/base_frequency of cpu0 (intel_pstate), -1 when absent
    uint64_t l1 = 0, l2 = 0, l3 = 0; // bytes, every cache counted once (shared_cpu_list)
};
CpuFacts readCpuFacts(const std::string &sysRoot, const std::string &procRoot);

// The processors' mean current speed in GHz (scaling_cur_freq of each cpuN), -1 when none reports it.
double meanCurrentGhz(const std::string &sysRoot);

// "48K", "1024K", "32M": a cache's size in bytes; 0 when it is not one.
uint64_t parseCacheSize(std::string_view text);

// /proc/uptime's first field, seconds; -1 when it cannot be read.
double readUptime(const std::string &procRoot);

struct DiskFacts {
    uint64_t capacity = 0; // size × 512
    int rotational = -1;   // queue/rotational: 1 HDD, 0 SSD, -1 unknown
    std::string model;     // device/model, trimmed
};
DiskFacts readDiskFacts(const std::string &sysRoot, const std::string &disk);

// "wifi" (a wireless directory), "ethernet" (type 1), or "" (anything else: a tunnel, a bridge's type is 1 too but it has
// a bridge directory, so "").
std::string netKind(const std::string &sysRoot, const std::string &interface);

// /proc/net/wireless: the interface's signal level in dBm, or 0 when it is not listed.
int wirelessSignal(std::string_view procNetWireless, std::string_view interface);

// The interface's addresses now (getifaddrs): IPv4 then IPv6, as text.
struct Addresses {
    std::vector<std::string> v4, v6;
};
Addresses interfaceAddresses(const std::string &interface);

} // namespace activity
