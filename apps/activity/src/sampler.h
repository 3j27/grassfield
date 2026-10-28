// The activity monitor's sampler (ADR-0038 b, c, d; docs/specs/activity.md AM20 to AM49, AM79): one sample reads the
// kernel's /proc and /sys files the tab shows and turns them into rows and summaries. Plain C++17 and POSIX, no Qt: it runs
// on a thread of its own in the app (step 2) and in `activity-sampler-bench` (tests/apps/activity_cost.sh). Every read it
// makes is counted, so the cost gates (AM-P2) can say which one went over.
//
// What it never does: read another owner's io, descriptors, command line or memory map; read environment variables; write
// anything; signal anything (step 2's actions live elsewhere).
#pragma once

#include "netdiag.h"
#include "procparse.h"
#include "units.h"

#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace activity
{

// What one sample reads (ADR-0038 d). The tabs combine them (readsForTab).
enum Read : unsigned {
    ReadProcesses = 1u << 0,   // the /proc listing and stat of every process
    ReadStatus = 1u << 1,      // status of every process (Memory tab; the real uid of every row)
    ReadIo = 1u << 2,          // io of own processes (Disk, Energy)
    ReadThreads = 1u << 3,     // the threads' status of one fifth of the own processes, in turn (Wake Ups)
    ReadDescriptors = 1u << 4, // the fd lists of one tenth of the own processes, in turn (sockets, GPU clients)
    ReadGpu = 1u << 5,         // fdinfo of the DRM descriptors found
    ReadSockets = 1u << 6,     // one TCP sock_diag dump
    ReadCommand = 1u << 7,     // the whole command line of own processes (the Command column)
    ReadSystemCpu = 1u << 8,   // /proc/stat, /proc/loadavg
    ReadSystemMemory = 1u << 9, // /proc/meminfo, /proc/pressure/memory, /proc/swaps, zram's mm_stat
    ReadSystemDisk = 1u << 10, // /proc/diskstats
    ReadSystemNet = 1u << 11,  // /proc/net/dev
};

enum class Tab { Cpu, Memory, Energy, Disk, Network };

unsigned readsForTab(Tab tab);

struct Options {
    std::string procRoot = "/proc";
    std::string sysRoot = "/sys";
    uint32_t uid = 0;             // the app's uid (getuid() by default, see defaultOptions)
    uint32_t uidMin = 1000;       // UID_MIN of /etc/login.defs
    long clockTicks = 100;        // sysconf(_SC_CLK_TCK)
    size_t maxKeptFiles = 0;      // kept /proc descriptors at most (0 keeps none; defaultOptions sets it from RLIMIT_NOFILE)
    int threadTurns = 5;          // AM23
    int descriptorTurns = 10;     // AM43, AM45
};

// Options for this machine: getuid(), /etc/login.defs, the clock tick, and a kept-descriptor budget from the soft
// RLIMIT_NOFILE minus a reserve of 256 for everything else the app opens.
Options defaultOptions();

// Raises the soft RLIMIT_NOFILE to the hard limit (at most 16384), so the kept /proc descriptors (about two per process)
// fit: the session's soft limit is 1024 (ADR-0038 d, spec AM-P2). Call it before defaultOptions(). Returns the soft limit in
// force afterwards.
size_t raiseFileLimit();

// Energy Impact (AM36, owner AQ3): %CPU + %GPU + 0.02 × wake-ups/s + 1.0 × disk MB/s (read and written, decimal MB), the
// provisional weights of the spec; an unknown term (-1) counts as 0.
double energyImpact(double cpuPercent, double gpuPercent, double wakeRate, double readRate, double writeRate);

// Memory pressure level (AM33).
enum class PressureLevel { Normal, Warning, Critical };

PressureLevel pressureLevel(const Meminfo &m, const Pressure &p);

struct ProcessRow {
    int pid = 0;
    uint64_t start = 0;  // stat field 22: with the pid, the row's identity
    int ppid = 0;
    int pgrp = 0;
    uint32_t uid = 0;
    bool own = false;
    bool systemAccount = false;
    char state = '?';
    long nice = 0;
    int threads = 0;
    std::string name;    // sanitized (AM17)
    std::string command; // own processes with ReadCommand, sanitized (AM28); "" otherwise
    std::string cgroup;  // the cgroup v2 path, raw
    Kind kind = Kind::Background;
    bool session = false;            // AM54
    bool efficiencyEligible = false; // AM68
    // CPU (AM20 to AM22): ticks since start; the share of one core since the previous sample, -1 at the first.
    uint64_t cpuTicks = 0;
    double cpuPercent = -1;
    uint64_t minorFaults = 0, majorFaults = 0;
    // Memory (AM30, AM31), bytes, with ReadStatus.
    bool hasMemory = false;
    uint64_t memory = 0, realMemory = 0, privateMemory = 0, sharedMemory = 0, swapped = 0, peakMemory = 0, virtualMemory = 0;
    // Disk (AM41), own processes with ReadIo.
    bool hasIo = false;
    uint64_t bytesRead = 0, bytesWritten = 0;
    double readRate = -1, writeRate = -1;
    // Wake Ups (AM23): voluntary context switches per second over the process's last turn, -1 until known.
    double wakeRate = -1;
    // Descriptors (AM25): -1 until the process's descriptor list was read.
    int openFiles = -1;
    // GPU (AM45, AM46).
    bool hasGpu = false;
    uint64_t gpuNs = 0;
    double gpuPercent = -1;
    // Network (AM43): TCP only, since the app opened.
    bool hasNet = false;
    uint64_t tcpSent = 0, tcpReceived = 0, tcpSegsOut = 0, tcpSegsIn = 0;
    // Energy Impact (AM36, AM37): own processes on the Energy tab's reads, -1 until the CPU share is known and always for
    // another owner (its io and descriptors are refused, so its index would leave terms out). The average is weighted by
    // time over the samples that computed it.
    double energyImpact = -1, averageEnergyImpact = -1;
};

// Every kernel thread summed (AM20a, AD25).
struct KernelRow {
    int threads = 0;
    uint64_t cpuTicks = 0;
    double cpuPercent = -1;
};

struct MemorySummary {
    bool ok = false;
    uint64_t physical = 0, used = 0, app = 0, wired = 0, compressed = 0, cached = 0, swapUsed = 0; // bytes (AD7)
    bool swapIsZramOnly = true; // AM34: the Compressed Memory column keeps its name
    double inUse = 0;           // the Memory Pressure graph's height (AM33)
    PressureLevel level = PressureLevel::Normal;
    bool hasPressure = false;
    uint64_t committed = 0, commitLimit = 0, available = 0;
};

struct DiskSnapshot {
    std::string name;
    uint64_t reads = 0, writes = 0, bytesRead = 0, bytesWritten = 0;
    double readsPerSec = -1, writesPerSec = -1, readBytesPerSec = -1, writeBytesPerSec = -1;
    double activeTime = -1;      // fraction of the interval with I/O in flight
    double responseMs = -1;      // mean time per completed request in the interval
};

struct NetSnapshot {
    std::string name;
    uint64_t packetsIn = 0, packetsOut = 0, bytesIn = 0, bytesOut = 0;
    double packetsInPerSec = -1, packetsOutPerSec = -1, bytesInPerSec = -1, bytesOutPerSec = -1;
};

struct GpuEngine {
    std::string name;
    double percent = 0;
};

struct GpuDevice {
    std::string pdev;
    std::string driver;
    std::vector<GpuEngine> engines;
    uint64_t memoryBytes = 0;
};

struct SystemSnapshot {
    bool cpuOk = false;
    double userShare = -1, systemShare = -1, idleShare = -1; // AM29, fractions of the whole machine
    bool sharesByOwner = false; // User and System as macOS means them (AD5), else the kernel's user/kernel split
    std::vector<double> perCpuBusy;                          // fractions, -1 at the first sample
    int tasks = -1;      // /proc/loadavg: every task, threads included
    int processes = 0;   // numeric entries of /proc
    MemorySummary memory;
    std::vector<DiskSnapshot> disks; // whole physical disks (AM42)
    DiskSnapshot diskTotal;
    std::vector<NetSnapshot> interfaces; // every interface but lo (AM44)
    NetSnapshot netTotal;
};

// What one sample read, for the cost gates (AM-P2) and the dev counters.
struct Counters {
    uint64_t listed = 0, statReads = 0, statusReads = 0, ioReads = 0, threadStatusReads = 0, fdListReads = 0, fdLinks = 0,
             fdinfoReads = 0, sockDumps = 0, cmdlineReads = 0, cgroupReads = 0, systemReads = 0;
    size_t keptFiles = 0;
};

struct Snapshot {
    std::vector<ProcessRow> rows; // kernel threads excluded, in pid order
    KernelRow kernel;
    SystemSnapshot system;
    std::vector<GpuDevice> gpus;
    double energyImpact = -1; // AM39's graph: the sum over the user's processes, -1 when no row has one
    Counters counters;
    double cpuMs = 0; // the sample's own CPU time on this thread (CLOCK_THREAD_CPUTIME_ID)
};

class Sampler
{
public:
    explicit Sampler(Options options);
    ~Sampler();
    Sampler(const Sampler &) = delete;
    Sampler &operator=(const Sampler &) = delete;

    // One sample at CLOCK_MONOTONIC's time, or at `now` (seconds, tests).
    Snapshot sample(unsigned reads);
    Snapshot sample(unsigned reads, double now);

    // The pids that own a window (the shell's projection, AM60): their processes are Apps (AM65).
    void setWindowOwners(std::unordered_set<int> pids);

    size_t keptFiles() const { return kept_; }

private:
    struct SocketTotals {
        uint64_t sent = 0, received = 0, segsOut = 0, segsIn = 0;
    };
    struct Proc {
        uint64_t start = 0;
        int statFd = -1, statusFd = -1;
        bool kthread = false;
        bool uidKnown = false;
        uint32_t uid = 0;
        std::string name, command, cgroup;
        bool haveTicks = false;
        uint64_t ticks = 0;
        double ticksTime = 0;
        bool haveIo = false;
        uint64_t ioRead = 0, ioWrite = 0;
        double ioTime = 0;
        double readRate = -1, writeRate = -1;
        bool haveCtx = false;
        uint64_t ctx = 0;
        double ctxTime = 0;
        double wakeRate = -1;
        bool scanned = false;
        int openFiles = -1;
        std::vector<int> drmFds;
        std::vector<uint64_t> sockets;
        std::map<std::string, uint64_t> engineNs; // "<pdev>|<client>|<engine>" → ns at the last sample
        double gpuTime = 0;
        bool haveGpu = false;
        uint64_t gpuNs = 0;
        double gpuPercent = -1;
        double energySum = 0, energyTime = 0; // Σ EI × seconds, Σ seconds (AM37)
        std::map<std::string, double> enginePercent; // "<pdev>|<engine>" → this process's share, for the GPUs
        std::unordered_map<uint64_t, TcpCounters> live; // its sockets seen in the dump
        SocketTotals closed;                            // sockets that went, their last counters
    };

    std::string procPath(int pid, const char *file) const;
    bool readKept(int &fd, const std::string &path, std::string &buf, uint64_t &counter);
    bool readFile(const std::string &path, std::string &buf);
    void closeProc(Proc &p);
    void readThreads(int pid, Proc &p, double now, Counters &c);
    void scanDescriptors(int pid, Proc &p, Counters &c);
    void readGpu(int pid, Proc &p, double now, Counters &c, std::map<std::string, GpuDevice> &devices,
                 std::unordered_set<std::string> &clientsSeen);
    void readSystem(unsigned reads, double now, SystemSnapshot &out, Counters &c);

    Options opt_;
    std::unordered_map<int, Proc> procs_;
    std::unordered_set<int> windowOwners_;
    std::unordered_map<uint64_t, int> socketOwner_; // inode → pid, from the descriptor scans
    size_t kept_ = 0;
    uint64_t index_ = 0; // samples taken: the turns of AM23 and AM43
    std::string buf_;
    // System state between samples.
    bool haveCpu_ = false;
    CpuTimes lastCpu_;
    std::vector<CpuTimes> lastPerCpu_;
    uint64_t cpuDeltaTicks_ = 0;                        // /proc/stat's total ticks between its last two reads
    uint64_t lastProcessIndex_ = UINT64_MAX - 1, lastCpuIndex_ = UINT64_MAX - 1;
    std::map<std::string, DiskStat> lastDisks_;
    std::map<std::string, NetDev> lastNet_;
    double lastDiskTime_ = -1, lastNetTime_ = -1;
    std::vector<std::string> physicalDisks_, zramDevices_;
    double devicesListedAt_ = -1e9;
};

} // namespace activity
