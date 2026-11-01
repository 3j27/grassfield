// Inspect (ADR-0038 AD13, AD45; docs/specs/activity.md AM57, AM58): one process read in detail for its window. Plain C++17
// and POSIX, no Qt, as the sampler; the window's backend runs it on the sampler's thread (AD35). Every read of the process
// goes through the /proc/<pid> directory descriptor opened after the start-time check (AM51's ProcessHandle): a pid taken
// again by another process is never read, and a read that fails says the process ended.
//
// What it never does: read another owner's io, descriptors, links, command line, cgroup or memory map (AD25: their stat,
// status and threads' status only); read environment variables; write anything.
#pragma once

#include "signals.h"

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace activity
{

// What one read covers beyond the header (stat, status, the parent's stat): the window's tab.
enum InspectRead : unsigned {
    InspectMemory = 1u << 0,     // smaps_rollup's Pss, at most every kPssSeconds (own processes)
    InspectStatistics = 1u << 1, // the threads' status; io, the unit, cmdline, exe and cwd (own processes)
    InspectFiles = 1u << 2,      // the descriptors and their sockets (own processes)
};

// AM58: smaps_rollup walks the whole address space (6.6 ms for 1 GiB, A8): read at most this often.
constexpr double kPssSeconds = 5;
// The descriptors listed at most; the others are counted (a process can hold a million).
constexpr size_t kMaxDescriptors = 10000;

// One line of Open Files and Ports (AM58).
struct Descriptor {
    enum class Kind { File, Pipe, Tcp, Udp, Local, Other };
    int fd = -1;
    Kind kind = Kind::Other;
    // File: its path; Local: its path ("" when it has none); Other: the kernel's own name ("anon_inode:[eventfd]",
    // "socket:[123]" for a socket of another family). Sanitized as AM17.
    std::string name;
    // Tcp and Udp: "address:port", "*" for any address, an IPv6 address in brackets; `remote` "" when there is none.
    std::string local, remote;
    bool listening = false; // Tcp: in LISTEN
};

struct ProcessDetails {
    // False: the process ended (or its pid names another process now); nothing else holds.
    bool alive = false;
    bool own = false; // its real uid is the app's (the sampler's rule)
    uint32_t uid = 0;
    std::string comm; // stat's name, sanitized
    char state = '?';
    // The header (AM57). The parent: its pid, and its start time and stat name when it is older than the process (a
    // younger one is a reused pid, AD40).
    int ppid = 0;
    bool hasParent = false;
    uint64_t parentStart = 0;
    std::string parentComm;
    int pgrp = 0;
    double cpuPercent = -1; // AM20 since the last read; -1 at the first, and after `forget`
    // Memory (AM58), bytes: status's fields, for every owner.
    bool hasMemory = false;
    uint64_t realMemory = 0, virtualMemory = 0, sharedMemory = 0, privateMemory = 0, swapped = 0, peakMemory = 0;
    int64_t proportionalMemory = -1; // smaps_rollup's Pss, own processes; -1 unknown
    // Statistics (AM58).
    int threads = 0;
    double userSeconds = 0, systemSeconds = 0;
    bool hasSwitches = false; // summed over the threads that answered
    uint64_t voluntarySwitches = 0, involuntarySwitches = 0;
    uint64_t minorFaults = 0, majorFaults = 0;
    int64_t readCalls = -1, writeCalls = -1; // io's syscr, syscw; -1 unknown
    double started = -1;                     // seconds since the epoch; -1 unknown (no btime)
    long nice = 0;
    int policy = -1;                         // stat field 41 (SCHED_*); -1 unknown
    std::string unit, command, executable, workingFolder; // sanitized; "" unknown
    // Open Files and Ports (AM58): in descriptor order.
    bool hasFiles = false;
    std::vector<Descriptor> files;
    size_t moreFiles = 0; // descriptors past kMaxDescriptors
    // This read's own CPU time on its thread (CLOCK_THREAD_CPUTIME_ID), for the cost (AM-P1).
    double cpuMs = 0;
};

class ProcessInspector
{
public:
    // `procRoot`: /proc or a fixture tree (AM79); `uid`: the app's; `clockTicks`: sysconf(_SC_CLK_TCK).
    ProcessInspector(std::string procRoot, uint32_t uid, long clockTicks);

    // AM51's check: /proc/<pid> opened as a directory, its stat read through it, the start time compared. False: the
    // process ended, or its pid names another one now; nothing is kept.
    bool open(int pid, uint64_t start);
    int pid() const { return m_handle.pid(); }
    uint64_t start() const { return m_handle.start(); }

    // One read at `now` (seconds, CLOCK_MONOTONIC); `what`: InspectRead bits. `forget`: % CPU starts again from this
    // read (the window was off screen, AM8).
    ProcessDetails read(unsigned what, double now, bool forget = false);

private:
    void readThreads(ProcessDetails &d);
    void readFiles(ProcessDetails &d);
    bool readAt(int dir, const char *name, std::string &out, size_t limit = 65536);
    std::string linkAt(int dir, const char *name);

    std::string m_procRoot;
    uint32_t m_uid;
    long m_clockTicks;
    ProcessHandle m_handle;
    double m_bootTime = -1; // /proc/stat's btime, read once
    bool m_haveTicks = false;
    uint64_t m_ticks = 0;
    double m_ticksTime = 0;
    double m_pssTime = -1;
    int64_t m_pss = -1;
    std::string m_buf;
};

// The parsers it uses (tests/unit/activity/tst_inspect.cpp).
// stat's field 41, the scheduling policy (SCHED_OTHER 0, FIFO 1, RR 2, BATCH 3, IDLE 5, DEADLINE 6).
bool parseStatPolicy(std::string_view stat, int &policy);
// smaps_rollup's "Pss:" in bytes.
bool parseSmapsPss(std::string_view text, uint64_t &bytes);
// /proc/stat's "btime" (seconds since the epoch).
bool parseBootTime(std::string_view text, uint64_t &seconds);
// A socket of /proc/<pid>/net/{tcp,tcp6,udp,udp6}, by inode.
struct InetSocket {
    std::string local, remote;
    bool listening = false;
    bool tcp = true;
};
// `v6`: the tcp6 or udp6 table (32-digit addresses); `tcp`: TCP (LISTEN is state 0A) or UDP. Adds to `out` by inode.
void parseInetSockets(std::string_view text, bool v6, bool tcp, std::unordered_map<uint64_t, InetSocket> &out);
// /proc/<pid>/net/unix: a socket's path by inode ("" for an unnamed one; an abstract name starts with "@").
void parseUnixSockets(std::string_view text, std::unordered_map<uint64_t, std::string> &out);
// The systemd unit of a cgroup v2 path: its last ".service" or ".scope" part, else its last ".slice"; "" for none.
std::string unitOfCgroup(std::string_view path);

} // namespace activity
