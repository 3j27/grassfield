// Parsers of the kernel's /proc and /sys text files the activity monitor reads (ADR-0038 b, docs/specs/activity.md AM20 to
// AM49). Pure functions over the bytes of one read: no file access, no allocation beyond the results, unit-tested on fixture
// texts (tests/unit/activity/tst_procparse.cpp). A field the text lacks keeps its default and its `has` flag stays false:
// the caller shows "—" rather than a made-up value (R11).
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace activity
{

// /proc/<pid>/stat. The short name (field 2) may hold spaces and parentheses: it runs from the first "(" to the last ")".
struct StatFields {
    int pid = 0;
    std::string comm;
    char state = '?';
    int ppid = 0;
    int pgrp = 0;
    unsigned long flags = 0;
    uint64_t minflt = 0, majflt = 0;
    uint64_t utime = 0, stime = 0; // clock ticks, the whole thread group
    long nice = 0;
    int numThreads = 0;
    uint64_t starttime = 0; // clock ticks after boot: with the pid, the row's identity
    uint64_t vsize = 0;     // bytes
    int64_t rssPages = 0;
    // Where the program's code is mapped (fields 26, 27): new at every exec (address-space randomization), so a change is
    // an exec even when stat's name stayed; 0 where the reader may not trace the process (another owner's).
    uint64_t startCode = 0, endCode = 0;
};

// The kernel's own flag for its threads (include/linux/sched.h PF_KTHREAD).
constexpr unsigned long kPfKthread = 0x00200000;

// `codeAddresses` false stops at field 24 (rss): the sampler asks for fields 26 and 27 of the processes it may trace only.
bool parseStat(std::string_view text, StatFields &out, bool codeAddresses = true);

// /proc/<pid>/status (only the fields the monitor shows; sizes in KiB as the kernel writes them).
struct StatusFields {
    std::string name;
    bool hasUid = false;
    uint32_t ruid = 0, euid = 0;
    int ppid = 0;
    bool hasMemory = false; // VmRSS present: a kernel thread has none
    uint64_t vmSizeKb = 0, vmRssKb = 0, rssAnonKb = 0, rssFileKb = 0, rssShmemKb = 0, vmSwapKb = 0, vmHwmKb = 0;
    bool hasCtx = false;
    uint64_t voluntaryCtx = 0, involuntaryCtx = 0;
};

// `switches` false stops at VmSwap, the last field the sampler needs of a process's status (the Memory tab, the owner).
bool parseStatus(std::string_view text, StatusFields &out, bool switches = true);
// voluntary_ctxt_switches of a thread's status (Wake Ups, AM23), found from the end of the file.
bool parseVoluntarySwitches(std::string_view text, uint64_t &out);

// /proc/<pid>/statm, in pages: the whole size, the resident set and its file and shared-memory part (`shared`), so
// resident - shared is RssAnon (fs/proc/task_mmu.c task_statm). Readable for every owner (A1).
struct Statm {
    uint64_t size = 0, resident = 0, shared = 0;
};
bool parseStatm(std::string_view text, Statm &out);

// /proc/<pid>/io (own processes only, A1).
struct IoFields {
    uint64_t rchar = 0, wchar = 0, syscr = 0, syscw = 0, readBytes = 0, writeBytes = 0, cancelledWriteBytes = 0;
};

bool parseIo(std::string_view text, IoFields &out);

// The cgroup v2 path of /proc/<pid>/cgroup (the "0::" line), "" when absent.
std::string parseCgroupV2(std::string_view text);

// The first word of /proc/<pid>/cmdline (NUL-separated) and every word joined by spaces.
std::string cmdlineFirstWord(std::string_view raw);
std::string cmdlineJoined(std::string_view raw);
std::string_view baseName(std::string_view path);

// AM17: the name of one of the user's own processes from its argv[0] (cmdlineFirstWord), its stat name and the target of
// its exe link. argv[0]'s basename when argv[0] is a plain path (no space) whose basename is the executable's or the stat
// name's (the invoked name, a symbolic link's included); else the executable's basename (" (deleted)" removed); else the
// stat name. So a title written over argv[0] (Chromium's and Electron's helpers, setproctitle, a login shell's "-bash")
// never names the process.
std::string processName(std::string_view argv0, std::string_view comm, std::string_view exePath);

// /proc/stat: the "cpu" line and one "cpuN" line per logical processor (ticks).
struct CpuTimes {
    uint64_t user = 0, nice = 0, system = 0, idle = 0, iowait = 0, irq = 0, softirq = 0, steal = 0;
    uint64_t idleAll() const { return idle + iowait; }
    uint64_t busy() const { return user + nice + system + irq + softirq + steal; }
    uint64_t total() const { return idleAll() + busy(); }
};

bool parseProcStat(std::string_view text, CpuTimes &total, std::vector<CpuTimes> &perCpu);

// The total of /proc/loadavg's fourth field ("running/total": every task the kernel schedules, threads included).
int parseLoadavgTasks(std::string_view text);

// /proc/meminfo (KiB).
struct Meminfo {
    bool ok = false;
    uint64_t memTotal = 0, memAvailable = 0, buffers = 0, cached = 0, activeFile = 0, inactiveFile = 0, sUnreclaim = 0,
             kernelStack = 0, pageTables = 0, unevictable = 0, shmem = 0, anonPages = 0, swapTotal = 0, swapFree = 0,
             committedAs = 0, commitLimit = 0;
};

bool parseMeminfo(std::string_view text, Meminfo &out);

// /proc/pressure/memory (percentages over ten seconds).
struct Pressure {
    bool ok = false;
    double someAvg10 = 0, fullAvg10 = 0;
};

bool parsePressure(std::string_view text, Pressure &out);

// /proc/swaps.
struct SwapDevice {
    std::string name;
    std::string type;
    uint64_t sizeKb = 0, usedKb = 0;
    bool zram() const;
};

std::vector<SwapDevice> parseSwaps(std::string_view text);

// /sys/block/zram<N>/mm_stat: its third field, the RAM the compressed pages take (bytes).
bool parseZramMemUsed(std::string_view text, uint64_t &bytes);

// /proc/diskstats.
struct DiskStat {
    std::string name;
    uint64_t reads = 0, sectorsRead = 0, readTicksMs = 0, writes = 0, sectorsWritten = 0, writeTicksMs = 0, ioTicksMs = 0;
};

// `only`, when given: the names kept, sorted (the whole physical disks, AM42); the other lines are not converted.
std::vector<DiskStat> parseDiskstats(std::string_view text, const std::vector<std::string> *only = nullptr);

// /proc/net/dev.
struct NetDev {
    std::string name;
    uint64_t rxBytes = 0, rxPackets = 0, txBytes = 0, txPackets = 0;
};

std::vector<NetDev> parseNetDev(std::string_view text);

// /proc/<pid>/fdinfo/<fd> of a DRM descriptor (Documentation/gpu/drm-usage-stats.rst): engine busy time in nanoseconds,
// engine capacity, memory per region in bytes. `ok` only when the text names a driver.
struct DrmClient {
    bool ok = false;
    std::string driver;
    std::string pdev;
    uint64_t clientId = 0;
    std::map<std::string, uint64_t> engineNs;
    std::map<std::string, uint64_t> engineCapacity;
    std::map<std::string, uint64_t> memoryBytes; // drm-memory-<region>, else drm-total-<region>
};

bool parseDrmFdinfo(std::string_view text, DrmClient &out);

// A sysfs PCI id file (`vendor`, `device`: "0x8086\n"); -1 when it is not one.
int parsePciId(std::string_view text);

// pci.ids (hwdata, AM47): the vendor's and the device's names for two ids, "" for what it does not list. Vendor lines are
// "<4 hex>  <name>", device lines a tab then "<4 hex>  <name>" under their vendor; comments start with '#'.
struct PciNames {
    std::string vendor, device;
};
PciNames lookupPciIds(std::string_view pciIds, int vendor, int device);

// The name a GPU shows (AM47), from pci.ids' names: the vendor's short name and the device's marketing name, "Intel UHD
// Graphics" for "Intel Corporation" and "CometLake-H GT2 [UHD Graphics]". The vendor's short name is the first part of
// its bracket ("[AMD/ATI]": AMD), else its name without a company suffix; the device's is its last bracket, else its name.
// "" without a device name.
std::string gpuModelName(const PciNames &names);

} // namespace activity
