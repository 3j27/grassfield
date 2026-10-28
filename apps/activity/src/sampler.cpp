#include "sampler.h"

#include "textclean.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <dirent.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace activity
{
namespace
{

constexpr size_t kBufSize = 65536;

double monotonicNow()
{
    timespec t{};
    clock_gettime(CLOCK_MONOTONIC, &t);
    return static_cast<double>(t.tv_sec) + static_cast<double>(t.tv_nsec) / 1e9;
}

double threadCpuMs()
{
    timespec t{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return static_cast<double>(t.tv_sec) * 1e3 + static_cast<double>(t.tv_nsec) / 1e6;
}

bool isNumeric(const char *s)
{
    if (!*s)
        return false;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9')
            return false;
    }
    return true;
}

double rate(uint64_t now, uint64_t before, double seconds)
{
    if (seconds <= 0 || now < before)
        return -1;
    return static_cast<double>(now - before) / seconds;
}

// lstat: /sys/block/<disk>/device is a link; its presence is what tells a whole physical disk.
bool exists(const std::string &path)
{
    struct stat st{};
    return lstat(path.c_str(), &st) == 0;
}

} // namespace

unsigned readsForTab(Tab tab)
{
    switch (tab) {
    case Tab::Cpu:
        return ReadProcesses | ReadDescriptors | ReadGpu | ReadSystemCpu;
    case Tab::Memory:
        return ReadProcesses | ReadStatus | ReadSystemMemory;
    case Tab::Energy:
        return ReadProcesses | ReadIo | ReadThreads | ReadDescriptors | ReadGpu | ReadSystemCpu;
    case Tab::Disk:
        return ReadProcesses | ReadIo | ReadSystemDisk;
    case Tab::Network:
        return ReadProcesses | ReadDescriptors | ReadSockets | ReadSystemNet;
    }
    return ReadProcesses;
}

Options defaultOptions()
{
    Options o;
    o.uid = getuid();
    const long tick = sysconf(_SC_CLK_TCK);
    o.clockTicks = tick > 0 ? tick : 100;
    std::string defs;
    if (FILE *f = std::fopen("/etc/login.defs", "re")) {
        char chunk[4096];
        size_t n = 0;
        while ((n = std::fread(chunk, 1, sizeof chunk, f)) > 0)
            defs.append(chunk, n);
        std::fclose(f);
    }
    o.uidMin = parseUidMin(defs);
    rlimit lim{};
    if (getrlimit(RLIMIT_NOFILE, &lim) == 0 && lim.rlim_cur != RLIM_INFINITY)
        o.maxKeptFiles = lim.rlim_cur > 256 ? static_cast<size_t>(lim.rlim_cur - 256) : 0;
    else
        o.maxKeptFiles = 4096;
    return o;
}

size_t raiseFileLimit()
{
    rlimit lim{};
    if (getrlimit(RLIMIT_NOFILE, &lim) != 0)
        return 0;
    const rlim_t wanted = lim.rlim_max == RLIM_INFINITY ? 16384 : std::min<rlim_t>(lim.rlim_max, 16384);
    if (lim.rlim_cur != RLIM_INFINITY && lim.rlim_cur < wanted) {
        rlimit raised = lim;
        raised.rlim_cur = wanted;
        if (setrlimit(RLIMIT_NOFILE, &raised) == 0)
            lim = raised;
    }
    return lim.rlim_cur == RLIM_INFINITY ? 16384 : static_cast<size_t>(lim.rlim_cur);
}

double energyImpact(double cpuPercent, double gpuPercent, double wakeRate, double readRate, double writeRate)
{
    const auto known = [](double v) { return v > 0 ? v : 0.0; };
    return known(cpuPercent) + known(gpuPercent) + 0.02 * known(wakeRate) + (known(readRate) + known(writeRate)) / 1e6;
}

PressureLevel pressureLevel(const Meminfo &m, const Pressure &p)
{
    // AM33 (provisional thresholds, pinned by tests/unit/activity/tst_memory.cpp).
    const double left = m.memTotal ? static_cast<double>(m.memAvailable) / static_cast<double>(m.memTotal) : 1.0;
    if ((p.ok && p.fullAvg10 >= 5.0) || left < 0.05)
        return PressureLevel::Critical;
    if ((p.ok && p.someAvg10 >= 10.0) || left < 0.15)
        return PressureLevel::Warning;
    return PressureLevel::Normal;
}

Sampler::Sampler(Options options)
    : opt_(std::move(options))
{
    buf_.resize(kBufSize);
    if (opt_.threadTurns < 1)
        opt_.threadTurns = 1;
    if (opt_.descriptorTurns < 1)
        opt_.descriptorTurns = 1;
    if (opt_.clockTicks <= 0)
        opt_.clockTicks = 100;
}

Sampler::~Sampler()
{
    for (auto &[pid, p] : procs_)
        closeProc(p);
}

void Sampler::setWindowOwners(std::unordered_set<int> pids)
{
    windowOwners_ = std::move(pids);
}

std::string Sampler::procPath(int pid, const char *file) const
{
    std::string s = opt_.procRoot;
    s += '/';
    s += std::to_string(pid);
    if (file && *file) {
        s += '/';
        s += file;
    }
    return s;
}

// Reads `path` into buf_ (its size set to the bytes read) through a kept descriptor when the budget allows (AD10, A10: a
// pread at offset 0 of an open /proc file costs less than an open, a read and a close). A kept descriptor of a process that
// ended fails its read (ESRCH): it is closed and false returned, so a pid reused since is never read through it.
bool Sampler::readKept(int &fd, const std::string &path, std::string &buf, uint64_t &counter)
{
    buf.resize(kBufSize);
    ++counter;
    if (fd >= 0) {
        const ssize_t n = pread(fd, buf.data(), buf.size(), 0);
        if (n > 0) {
            buf.resize(static_cast<size_t>(n));
            return true;
        }
        close(fd);
        fd = -1;
        --kept_;
        return false;
    }
    const int f = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    const ssize_t n = read(f, buf.data(), buf.size());
    if (n <= 0) {
        close(f);
        return false;
    }
    buf.resize(static_cast<size_t>(n));
    if (kept_ < opt_.maxKeptFiles) {
        fd = f;
        ++kept_;
    } else {
        close(f);
    }
    return true;
}

bool Sampler::readFile(const std::string &path, std::string &buf)
{
    buf.clear();
    const int f = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    char chunk[8192];
    for (;;) {
        const ssize_t n = read(f, chunk, sizeof chunk);
        if (n < 0) {
            close(f);
            return false;
        }
        if (n == 0)
            break;
        buf.append(chunk, static_cast<size_t>(n));
        if (buf.size() > (1u << 20)) // no /proc file the monitor reads is this long: stop rather than grow without end
            break;
    }
    close(f);
    return true;
}

void Sampler::closeProc(Proc &p)
{
    if (p.statFd >= 0) {
        close(p.statFd);
        p.statFd = -1;
        --kept_;
    }
    if (p.statusFd >= 0) {
        close(p.statusFd);
        p.statusFd = -1;
        --kept_;
    }
}

void Sampler::readThreads(int pid, Proc &p, double now, Counters &c)
{
    const std::string dir = procPath(pid, "task");
    DIR *d = opendir(dir.c_str());
    if (!d)
        return;
    uint64_t sum = 0;
    std::string tbuf;
    while (dirent *e = readdir(d)) {
        if (!isNumeric(e->d_name))
            continue;
        ++c.threadStatusReads;
        if (!readFile(dir + '/' + e->d_name + "/status", tbuf))
            continue;
        StatusFields st;
        if (parseStatus(tbuf, st) && st.hasCtx)
            sum += st.voluntaryCtx;
    }
    closedir(d);
    // A thread that ended takes its switches with it: a sum below the last one gives no rate this turn, the baseline moves.
    if (p.haveCtx && sum >= p.ctx && now > p.ctxTime)
        p.wakeRate = rate(sum, p.ctx, now - p.ctxTime);
    p.ctx = sum;
    p.ctxTime = now;
    p.haveCtx = true;
}

void Sampler::scanDescriptors(int pid, Proc &p, Counters &c)
{
    const std::string dir = procPath(pid, "fd");
    DIR *d = opendir(dir.c_str());
    ++c.fdListReads;
    if (!d) {
        p.scanned = true; // refused (non-dumpable): "—", and the turn comes again
        p.openFiles = -1;
        return;
    }
    for (uint64_t inode : p.sockets) {
        auto it = socketOwner_.find(inode);
        if (it != socketOwner_.end() && it->second == pid)
            socketOwner_.erase(it);
    }
    p.sockets.clear();
    p.drmFds.clear();
    int count = 0;
    char target[512];
    while (dirent *e = readdir(d)) {
        if (!isNumeric(e->d_name))
            continue;
        ++count;
        ++c.fdLinks;
        const ssize_t n = readlinkat(dirfd(d), e->d_name, target, sizeof target - 1);
        if (n <= 0)
            continue;
        target[n] = '\0';
        if (std::strncmp(target, "socket:[", 8) == 0) {
            const uint64_t inode = std::strtoull(target + 8, nullptr, 10);
            if (inode) {
                p.sockets.push_back(inode);
                socketOwner_[inode] = pid;
            }
        } else if (std::strncmp(target, "/dev/dri/", 9) == 0) {
            p.drmFds.push_back(std::atoi(e->d_name));
        }
    }
    closedir(d);
    p.openFiles = count;
    p.scanned = true;
}

void Sampler::readGpu(int pid, Proc &p, double now, Counters &c, std::map<std::string, GpuDevice> &devices,
                      std::unordered_set<std::string> &clientsSeen)
{
    std::map<std::string, uint64_t> nowNs;
    std::map<std::string, double> perEngine; // "<pdev>|<engine>" → this process's share
    uint64_t total = 0;
    bool any = false;
    const double dt = p.haveGpu ? now - p.gpuTime : 0;
    std::string fbuf;
    for (int fd : p.drmFds) {
        ++c.fdinfoReads;
        if (!readFile(procPath(pid, "fdinfo") + '/' + std::to_string(fd), fbuf))
            continue;
        DrmClient client;
        if (!parseDrmFdinfo(fbuf, client) || client.engineNs.empty())
            continue;
        const std::string key = client.pdev + '|' + std::to_string(client.clientId);
        if (!clientsSeen.insert(key).second)
            continue; // the same client through another descriptor (or a process that shares it)
        any = true;
        GpuDevice &dev = devices[client.pdev];
        dev.pdev = client.pdev;
        dev.driver = client.driver;
        for (const auto &[region, bytes] : client.memoryBytes)
            dev.memoryBytes += bytes;
        for (const auto &[engine, ns] : client.engineNs) {
            const std::string k = key + '|' + engine;
            nowNs[k] = ns;
            total += ns;
            auto last = p.engineNs.find(k);
            if (last == p.engineNs.end() || dt <= 0 || ns < last->second)
                continue;
            uint64_t cap = 1;
            auto capIt = client.engineCapacity.find(engine);
            if (capIt != client.engineCapacity.end() && capIt->second > 0)
                cap = capIt->second;
            const double share = static_cast<double>(ns - last->second) / (dt * 1e9 * static_cast<double>(cap)) * 100.0;
            perEngine[client.pdev + '|' + engine] += share;
        }
    }
    if (!any) {
        p.haveGpu = false;
        p.gpuPercent = -1;
        p.engineNs.clear();
        p.enginePercent.clear();
        return;
    }
    double busiest = p.haveGpu ? 0.0 : -1.0;
    for (const auto &[k, share] : perEngine)
        busiest = std::max(busiest, std::min(share, 100.0));
    p.gpuPercent = busiest;
    p.enginePercent = perEngine;
    p.engineNs = std::move(nowNs);
    p.gpuNs = total;
    p.gpuTime = now;
    p.haveGpu = true;
}

Snapshot Sampler::sample(unsigned reads)
{
    return sample(reads, monotonicNow());
}

Snapshot Sampler::sample(unsigned reads, double now)
{
    const double cpu0 = threadCpuMs();
    Snapshot s;
    Counters &c = s.counters;
    uint64_t ownDelta = 0;
    bool ownDeltaKnown = false;
    std::map<std::string, GpuDevice> devices;
    std::unordered_set<std::string> clientsSeen;

    if (reads & ReadProcesses) {
        ownDeltaKnown = true;
        std::vector<std::pair<int, uint32_t>> listing;
        listing.reserve(procs_.size() + 64);
        if (DIR *d = opendir(opt_.procRoot.c_str())) {
            while (dirent *e = readdir(d)) {
                if (!isNumeric(e->d_name))
                    continue;
                struct stat st{};
                if (fstatat(dirfd(d), e->d_name, &st, 0) != 0)
                    continue;
                listing.emplace_back(std::atoi(e->d_name), static_cast<uint32_t>(st.st_uid));
            }
            closedir(d);
        }
        c.listed = listing.size();
        s.system.processes = static_cast<int>(listing.size());
        std::sort(listing.begin(), listing.end());
        std::unordered_set<int> present;
        present.reserve(listing.size());
        double kernelPercent = 0;
        bool kernelKnown = false;

        for (const auto &[pid, dirUid] : listing) {
            auto found = procs_.find(pid);
            bool fresh = found == procs_.end();
            Proc &p = procs_[pid];
            if (!readKept(p.statFd, procPath(pid, "stat"), buf_, c.statReads)) {
                if (fresh) {
                    procs_.erase(pid);
                    continue;
                }
                // The kept descriptor's process ended; the pid may have a new one.
                closeProc(p);
                p = Proc{};
                fresh = true;
                if (!readKept(p.statFd, procPath(pid, "stat"), buf_, c.statReads)) {
                    procs_.erase(pid);
                    continue;
                }
            }
            StatFields st;
            if (!parseStat(buf_, st)) {
                closeProc(p);
                procs_.erase(pid);
                continue;
            }
            if (!fresh && st.starttime != p.start) { // a pid reused, read by path: another process
                closeProc(p);
                p = Proc{};
                fresh = true;
                readKept(p.statFd, procPath(pid, "stat"), buf_, c.statReads);
                if (!parseStat(buf_, st)) {
                    procs_.erase(pid);
                    continue;
                }
            }
            p.start = st.starttime;
            p.kthread = (st.flags & kPfKthread) != 0;
            present.insert(pid);
            const uint64_t ticks = st.utime + st.stime;
            double percent = -1;
            const double cpuSeconds = now - p.ticksTime;
            if (p.haveTicks && now > p.ticksTime && ticks >= p.ticks)
                percent = static_cast<double>(ticks - p.ticks) / (cpuSeconds * static_cast<double>(opt_.clockTicks)) * 100.0;

            if (p.kthread) {
                s.kernel.threads += 1;
                s.kernel.cpuTicks += ticks;
                if (percent >= 0) {
                    kernelPercent += percent;
                    kernelKnown = true;
                }
                p.ticks = ticks;
                p.ticksTime = now;
                p.haveTicks = true;
                continue;
            }

            // The owner: the real uid of status when it is read; else the directory's owner (the effective uid), except
            // that a directory owned by root may hide a non-dumpable process of anyone: status tells (the spec's Terms).
            StatusFields status;
            bool haveStatus = false;
            if ((reads & ReadStatus) || (dirUid == 0 && !p.uidKnown)) {
                if (readKept(p.statusFd, procPath(pid, "status"), buf_, c.statusReads))
                    haveStatus = parseStatus(buf_, status);
            }
            uint32_t uid = dirUid;
            if (haveStatus && status.hasUid) {
                uid = status.ruid;
                p.uid = uid;
                p.uidKnown = true;
            } else if (dirUid == 0 && p.uidKnown) {
                uid = p.uid;
            }
            const bool own = uid == opt_.uid;

            if (fresh) {
                ++c.cgroupReads;
                if (readFile(procPath(pid, "cgroup"), buf_))
                    p.cgroup = parseCgroupV2(buf_);
                std::string name;
                if (own) {
                    ++c.cmdlineReads;
                    if (readFile(procPath(pid, "cmdline"), buf_)) {
                        name = std::string(baseName(cmdlineFirstWord(buf_)));
                        if (reads & ReadCommand)
                            p.command = sanitizeDisplay(cmdlineJoined(buf_));
                    }
                }
                // Another owner's name is the kernel's short name, never its cmdline: an argv[0] can be a title (AD25).
                p.name = sanitizeDisplay(name.empty() ? st.comm : name);
            } else if (own && (reads & ReadCommand) && p.command.empty()) {
                ++c.cmdlineReads;
                if (readFile(procPath(pid, "cmdline"), buf_))
                    p.command = sanitizeDisplay(cmdlineJoined(buf_));
            }

            ProcessRow row;
            row.pid = pid;
            row.start = st.starttime;
            row.ppid = st.ppid;
            row.pgrp = st.pgrp;
            row.uid = uid;
            row.own = own;
            row.systemAccount = uid < opt_.uidMin;
            row.state = st.state;
            row.nice = st.nice;
            row.threads = st.numThreads;
            row.name = p.name;
            row.command = own ? p.command : std::string();
            row.cgroup = p.cgroup;
            row.kind = classify(p.cgroup, own, row.systemAccount, windowOwners_.count(pid) != 0);
            row.session = own && isSessionProcess(p.cgroup);
            row.efficiencyEligible = own && efficiencyEligible(p.cgroup);
            row.cpuTicks = ticks;
            row.cpuPercent = percent;
            row.minorFaults = st.minflt;
            row.majorFaults = st.majflt;
            if (own && p.haveTicks && ticks >= p.ticks)
                ownDelta += ticks - p.ticks;
            p.ticks = ticks;
            p.ticksTime = now;
            p.haveTicks = true;

            if ((reads & ReadStatus) && haveStatus && status.hasMemory) {
                row.hasMemory = true;
                row.memory = (status.rssAnonKb + status.vmSwapKb) * 1024;
                row.realMemory = status.vmRssKb * 1024;
                row.privateMemory = status.rssAnonKb * 1024;
                row.sharedMemory = (status.rssFileKb + status.rssShmemKb) * 1024;
                row.swapped = status.vmSwapKb * 1024;
                row.peakMemory = status.vmHwmKb * 1024;
                row.virtualMemory = status.vmSizeKb * 1024;
            }

            if (own && (reads & ReadIo)) {
                ++c.ioReads;
                IoFields io;
                if (readFile(procPath(pid, "io"), buf_) && parseIo(buf_, io)) {
                    if (p.haveIo && now > p.ioTime) {
                        p.readRate = rate(io.readBytes, p.ioRead, now - p.ioTime);
                        p.writeRate = rate(io.writeBytes, p.ioWrite, now - p.ioTime);
                    }
                    p.ioRead = io.readBytes;
                    p.ioWrite = io.writeBytes;
                    p.ioTime = now;
                    p.haveIo = true;
                    row.hasIo = true;
                    row.bytesRead = io.readBytes;
                    row.bytesWritten = io.writeBytes;
                    row.readRate = p.readRate;
                    row.writeRate = p.writeRate;
                } else {
                    p.haveIo = false;
                }
            }

            if (own && (reads & ReadThreads)) {
                const bool turn = !p.haveCtx || static_cast<int>(index_ % opt_.threadTurns) == pid % opt_.threadTurns;
                if (turn)
                    readThreads(pid, p, now, c);
                row.wakeRate = p.wakeRate;
            }

            if (own && (reads & ReadDescriptors)) {
                const bool turn = !p.scanned || static_cast<int>(index_ % opt_.descriptorTurns) == pid % opt_.descriptorTurns;
                if (turn) {
                    scanDescriptors(pid, p, c);
                    if (!fresh) { // its unit may have changed (moved into a scope): read again in its turn
                        ++c.cgroupReads;
                        if (readFile(procPath(pid, "cgroup"), buf_))
                            p.cgroup = parseCgroupV2(buf_);
                    }
                }
                row.openFiles = p.openFiles;
            }

            if (own && (reads & ReadGpu) && !p.drmFds.empty()) {
                readGpu(pid, p, now, c, devices, clientsSeen);
                row.hasGpu = p.haveGpu;
                row.gpuNs = p.gpuNs;
                row.gpuPercent = p.gpuPercent;
            }

            if (own && (reads & ReadIo) && (reads & ReadThreads) && percent >= 0) {
                row.energyImpact = energyImpact(percent, row.gpuPercent, row.wakeRate, row.readRate, row.writeRate);
                p.energySum += row.energyImpact * cpuSeconds;
                p.energyTime += cpuSeconds;
                row.averageEnergyImpact = p.energySum / p.energyTime;
                s.energyImpact = (s.energyImpact < 0 ? 0 : s.energyImpact) + row.energyImpact;
            }

            s.rows.push_back(std::move(row));
        }
        s.kernel.cpuPercent = kernelKnown ? kernelPercent : -1;

        // Processes that ended: their descriptors and their sockets' owner entries go.
        for (auto it = procs_.begin(); it != procs_.end();) {
            if (present.count(it->first)) {
                ++it;
                continue;
            }
            for (uint64_t inode : it->second.sockets) {
                auto o = socketOwner_.find(inode);
                if (o != socketOwner_.end() && o->second == it->first)
                    socketOwner_.erase(o);
            }
            closeProc(it->second);
            it = procs_.erase(it);
        }

        if (reads & ReadSockets) {
            ++c.sockDumps;
            std::vector<TcpCounters> dump;
            std::unordered_map<uint64_t, TcpCounters> byInode;
            if (dumpTcpSockets(dump)) {
                byInode.reserve(dump.size());
                for (const TcpCounters &t : dump)
                    byInode[t.inode] = t;
            }
            for (ProcessRow &row : s.rows) {
                if (!row.own)
                    continue;
                Proc &p = procs_[row.pid];
                if (!p.scanned)
                    continue;
                // A socket seen before and gone from the dump closed: its last counters stay with the process.
                for (auto it = p.live.begin(); it != p.live.end();) {
                    if (byInode.count(it->first)) {
                        ++it;
                        continue;
                    }
                    p.closed.sent += it->second.bytesAcked;
                    p.closed.received += it->second.bytesReceived;
                    p.closed.segsOut += it->second.segsOut;
                    p.closed.segsIn += it->second.segsIn;
                    it = p.live.erase(it);
                }
                for (uint64_t inode : p.sockets) {
                    auto f = byInode.find(inode);
                    if (f != byInode.end())
                        p.live[inode] = f->second;
                }
                row.hasNet = true;
                row.tcpSent = p.closed.sent;
                row.tcpReceived = p.closed.received;
                row.tcpSegsOut = p.closed.segsOut;
                row.tcpSegsIn = p.closed.segsIn;
                for (const auto &[inode, t] : p.live) {
                    row.tcpSent += t.bytesAcked;
                    row.tcpReceived += t.bytesReceived;
                    row.tcpSegsOut += t.segsOut;
                    row.tcpSegsIn += t.segsIn;
                }
            }
        }

        // The GPUs: each engine's share summed over the user's clients (the compositor among them), capped at 100 (AM47).
        if (reads & ReadGpu) {
            std::map<std::string, std::map<std::string, double>> engines;
            for (const ProcessRow &row : s.rows) {
                if (!row.hasGpu)
                    continue;
                for (const auto &[k, share] : procs_[row.pid].enginePercent) {
                    const size_t bar = k.find('|');
                    engines[k.substr(0, bar)][k.substr(bar + 1)] += share;
                }
            }
            for (auto &[pdev, dev] : devices) {
                for (const auto &[engine, share] : engines[pdev])
                    dev.engines.push_back({engine, std::min(share, 100.0)});
                s.gpus.push_back(dev);
            }
        }
    }

    readSystem(reads, now, s.system, c);

    // AM29: User = the user's processes, System = every other non-idle tick, Idle = the rest (macOS's meaning, AD5). Only
    // when this sample and the previous one both read the processes and /proc/stat, so both deltas span the same interval;
    // otherwise the kernel's split stays (sharesByOwner false: the Dock's CPU graph while the window is hidden, AM62).
    if (ownDeltaKnown && cpuDeltaTicks_ > 0 && lastProcessIndex_ + 1 == index_ && lastCpuIndex_ + 1 == index_
        && s.system.userShare >= 0) {
        const double busy = s.system.userShare + s.system.systemShare;
        const double user = std::min(busy, static_cast<double>(ownDelta) / static_cast<double>(cpuDeltaTicks_));
        s.system.userShare = user;
        s.system.systemShare = std::max(0.0, busy - user);
        s.system.sharesByOwner = true;
    }
    if (reads & ReadProcesses)
        lastProcessIndex_ = index_;
    if ((reads & ReadSystemCpu) && s.system.cpuOk)
        lastCpuIndex_ = index_;

    c.keptFiles = kept_;
    ++index_;
    s.cpuMs = threadCpuMs() - cpu0;
    return s;
}

void Sampler::readSystem(unsigned reads, double now, SystemSnapshot &out, Counters &c)
{
    if (now - devicesListedAt_ >= 10.0 && (reads & (ReadSystemMemory | ReadSystemDisk))) {
        physicalDisks_.clear();
        zramDevices_.clear();
        const std::string block = opt_.sysRoot + "/block";
        if (DIR *d = opendir(block.c_str())) {
            while (dirent *e = readdir(d)) {
                if (e->d_name[0] == '.')
                    continue;
                const std::string name = e->d_name;
                if (name.compare(0, 4, "zram") == 0)
                    zramDevices_.push_back(name);
                else if (exists(block + '/' + name + "/device")) // whole physical disks: no loop, zram, dm or md (AM42)
                    physicalDisks_.push_back(name);
            }
            closedir(d);
        }
        std::sort(physicalDisks_.begin(), physicalDisks_.end());
        std::sort(zramDevices_.begin(), zramDevices_.end());
        devicesListedAt_ = now;
    }

    if (reads & ReadSystemCpu) {
        ++c.systemReads;
        CpuTimes total;
        std::vector<CpuTimes> per;
        if (readFile(opt_.procRoot + "/stat", buf_) && parseProcStat(buf_, total, per)) {
            out.cpuOk = true;
            cpuDeltaTicks_ = 0;
            if (haveCpu_ && total.total() > lastCpu_.total()) {
                cpuDeltaTicks_ = total.total() - lastCpu_.total();
                const double dt = static_cast<double>(cpuDeltaTicks_);
                const double idle = static_cast<double>(total.idleAll() - std::min(total.idleAll(), lastCpu_.idleAll())) / dt;
                const double busy = static_cast<double>(total.busy() - std::min(total.busy(), lastCpu_.busy())) / dt;
                out.idleShare = std::min(1.0, idle);
                // The kernel's split (user mode against kernel mode); sample() replaces it by macOS's meaning when it read
                // the processes (AM29).
                out.userShare = static_cast<double>((total.user + total.nice) - std::min(total.user + total.nice, lastCpu_.user + lastCpu_.nice)) / dt;
                out.systemShare = std::max(0.0, busy - out.userShare);
            }
            out.perCpuBusy.assign(per.size(), -1);
            if (haveCpu_ && per.size() == lastPerCpu_.size()) {
                for (size_t i = 0; i < per.size(); ++i) {
                    const uint64_t t = per[i].total(), t0 = lastPerCpu_[i].total();
                    if (t > t0)
                        out.perCpuBusy[i] = static_cast<double>(per[i].busy() - std::min(per[i].busy(), lastPerCpu_[i].busy())) / static_cast<double>(t - t0);
                }
            }
            lastCpu_ = total;
            lastPerCpu_ = per;
            haveCpu_ = true;
        }
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/loadavg", buf_))
            out.tasks = parseLoadavgTasks(buf_);
    }

    if (reads & ReadSystemMemory) {
        ++c.systemReads;
        Meminfo m;
        if (readFile(opt_.procRoot + "/meminfo", buf_) && parseMeminfo(buf_, m)) {
            Pressure pr;
            ++c.systemReads;
            if (readFile(opt_.procRoot + "/pressure/memory", buf_))
                parsePressure(buf_, pr);
            ++c.systemReads;
            std::vector<SwapDevice> swaps;
            if (readFile(opt_.procRoot + "/swaps", buf_))
                swaps = parseSwaps(buf_);
            uint64_t zram = 0;
            for (const std::string &z : zramDevices_) {
                ++c.systemReads;
                uint64_t used = 0;
                if (readFile(opt_.sysRoot + "/block/" + z + "/mm_stat", buf_) && parseZramMemUsed(buf_, used))
                    zram += used;
            }
            MemorySummary &ms = out.memory;
            ms.ok = true;
            ms.physical = m.memTotal * 1024;
            ms.available = m.memAvailable * 1024;
            ms.used = (m.memTotal - std::min(m.memTotal, m.memAvailable)) * 1024;
            ms.compressed = zram;
            ms.wired = (m.sUnreclaim + m.kernelStack + m.pageTables + m.unevictable) * 1024;
            ms.app = ms.used > ms.wired + ms.compressed ? ms.used - ms.wired - ms.compressed : 0;
            ms.cached = (m.activeFile + m.inactiveFile) * 1024;
            ms.swapUsed = 0;
            ms.swapIsZramOnly = true;
            for (const SwapDevice &sw : swaps) {
                if (sw.zram())
                    continue;
                ms.swapUsed += sw.usedKb * 1024;
                ms.swapIsZramOnly = false;
            }
            ms.inUse = m.memTotal ? static_cast<double>(m.memTotal - std::min(m.memTotal, m.memAvailable)) / static_cast<double>(m.memTotal) : 0;
            ms.hasPressure = pr.ok;
            ms.level = pressureLevel(m, pr);
            ms.committed = m.committedAs * 1024;
            ms.commitLimit = m.commitLimit * 1024;
        }
    }

    if (reads & ReadSystemDisk) {
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/diskstats", buf_)) {
            const double dt = lastDiskTime_ >= 0 ? now - lastDiskTime_ : 0;
            std::map<std::string, DiskStat> nowDisks;
            for (DiskStat &d : parseDiskstats(buf_)) {
                if (!std::binary_search(physicalDisks_.begin(), physicalDisks_.end(), d.name))
                    continue;
                DiskSnapshot ds;
                ds.name = d.name;
                ds.reads = d.reads;
                ds.writes = d.writes;
                ds.bytesRead = d.sectorsRead * 512;
                ds.bytesWritten = d.sectorsWritten * 512;
                auto last = lastDisks_.find(d.name);
                if (last != lastDisks_.end() && dt > 0) {
                    const DiskStat &l = last->second;
                    ds.readsPerSec = rate(d.reads, l.reads, dt);
                    ds.writesPerSec = rate(d.writes, l.writes, dt);
                    ds.readBytesPerSec = rate(d.sectorsRead * 512, l.sectorsRead * 512, dt);
                    ds.writeBytesPerSec = rate(d.sectorsWritten * 512, l.sectorsWritten * 512, dt);
                    if (d.ioTicksMs >= l.ioTicksMs)
                        ds.activeTime = std::min(1.0, static_cast<double>(d.ioTicksMs - l.ioTicksMs) / (dt * 1000.0));
                    const uint64_t ops = (d.reads + d.writes) - std::min(d.reads + d.writes, l.reads + l.writes);
                    const uint64_t ms = (d.readTicksMs + d.writeTicksMs) - std::min(d.readTicksMs + d.writeTicksMs, l.readTicksMs + l.writeTicksMs);
                    ds.responseMs = ops ? static_cast<double>(ms) / static_cast<double>(ops) : 0;
                }
                out.diskTotal.reads += ds.reads;
                out.diskTotal.writes += ds.writes;
                out.diskTotal.bytesRead += ds.bytesRead;
                out.diskTotal.bytesWritten += ds.bytesWritten;
                nowDisks[d.name] = d;
                out.disks.push_back(std::move(ds));
            }
            if (dt > 0 && !out.disks.empty()) {
                out.diskTotal.readsPerSec = out.diskTotal.writesPerSec = out.diskTotal.readBytesPerSec = out.diskTotal.writeBytesPerSec = 0;
                for (const DiskSnapshot &ds : out.disks) {
                    if (ds.readsPerSec < 0) // a disk new since the last sample: no total rate this time
                        continue;
                    out.diskTotal.readsPerSec += ds.readsPerSec;
                    out.diskTotal.writesPerSec += ds.writesPerSec;
                    out.diskTotal.readBytesPerSec += ds.readBytesPerSec;
                    out.diskTotal.writeBytesPerSec += ds.writeBytesPerSec;
                }
            }
            out.diskTotal.name = "total";
            lastDisks_ = std::move(nowDisks);
            lastDiskTime_ = now;
        }
    }

    if (reads & ReadSystemNet) {
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/net/dev", buf_)) {
            const double dt = lastNetTime_ >= 0 ? now - lastNetTime_ : 0;
            std::map<std::string, NetDev> nowNet;
            bool rates = dt > 0;
            for (NetDev &n : parseNetDev(buf_)) {
                if (n.name == "lo")
                    continue;
                NetSnapshot ns;
                ns.name = n.name;
                ns.packetsIn = n.rxPackets;
                ns.packetsOut = n.txPackets;
                ns.bytesIn = n.rxBytes;
                ns.bytesOut = n.txBytes;
                auto last = lastNet_.find(n.name);
                if (last != lastNet_.end() && dt > 0) {
                    ns.packetsInPerSec = rate(n.rxPackets, last->second.rxPackets, dt);
                    ns.packetsOutPerSec = rate(n.txPackets, last->second.txPackets, dt);
                    ns.bytesInPerSec = rate(n.rxBytes, last->second.rxBytes, dt);
                    ns.bytesOutPerSec = rate(n.txBytes, last->second.txBytes, dt);
                } else {
                    rates = false;
                }
                out.netTotal.packetsIn += ns.packetsIn;
                out.netTotal.packetsOut += ns.packetsOut;
                out.netTotal.bytesIn += ns.bytesIn;
                out.netTotal.bytesOut += ns.bytesOut;
                nowNet[n.name] = n;
                out.interfaces.push_back(std::move(ns));
            }
            if (rates) {
                out.netTotal.packetsInPerSec = out.netTotal.packetsOutPerSec = out.netTotal.bytesInPerSec = out.netTotal.bytesOutPerSec = 0;
                for (const NetSnapshot &ns : out.interfaces) {
                    out.netTotal.packetsInPerSec += std::max(0.0, ns.packetsInPerSec);
                    out.netTotal.packetsOutPerSec += std::max(0.0, ns.packetsOutPerSec);
                    out.netTotal.bytesInPerSec += std::max(0.0, ns.bytesInPerSec);
                    out.netTotal.bytesOutPerSec += std::max(0.0, ns.bytesOutPerSec);
                }
            }
            out.netTotal.name = "total";
            lastNet_ = std::move(nowNet);
            lastNetTime_ = now;
        }
    }
}

} // namespace activity
