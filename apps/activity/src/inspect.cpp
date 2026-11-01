#include "inspect.h"

#include "procparse.h"
#include "textclean.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <charconv>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

namespace activity
{
namespace
{

double threadCpuMs()
{
    timespec ts{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return static_cast<double>(ts.tv_sec) * 1e3 + static_cast<double>(ts.tv_nsec) / 1e6;
}

bool startsWith(std::string_view text, std::string_view prefix)
{
    return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

template <typename T>
bool number(std::string_view text, T &out, int base = 10)
{
    const auto r = std::from_chars(text.data(), text.data() + text.size(), out, base);
    return r.ec == std::errc() && r.ptr != text.data();
}

// The whitespace-separated words of one line.
std::vector<std::string_view> words(std::string_view line)
{
    std::vector<std::string_view> out;
    size_t pos = 0;
    while (pos < line.size()) {
        while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t'))
            ++pos;
        size_t end = pos;
        while (end < line.size() && line[end] != ' ' && line[end] != '\t')
            ++end;
        if (end > pos)
            out.push_back(line.substr(pos, end - pos));
        pos = end;
    }
    return out;
}

// Calls `f` with each line of `text` after the first (the tables' header).
template <typename F>
void eachRow(std::string_view text, F f)
{
    size_t pos = text.find('\n');
    while (pos != std::string_view::npos && pos + 1 < text.size()) {
        const size_t start = pos + 1;
        pos = text.find('\n', start);
        f(text.substr(start, pos == std::string_view::npos ? std::string_view::npos : pos - start));
    }
}

// "0100007F:0277" (tcp, udp) or a 32-digit address (tcp6, udp6) → "127.0.0.1:631", "[::1]:631", "*:631". The kernel prints
// each 32-bit word of the address as it lies in memory (%08X of a native u32) and the port in host order.
bool inetAddress(std::string_view hex, bool v6, std::string &out, bool &any)
{
    const size_t colon = hex.find(':');
    const size_t digits = v6 ? 32 : 8;
    if (colon != digits)
        return false;
    unsigned char bytes[16] = {};
    for (size_t word = 0; word < digits / 8; ++word) {
        uint32_t w = 0;
        if (!number(hex.substr(word * 8, 8), w, 16))
            return false;
        std::memcpy(bytes + word * 4, &w, 4);
    }
    unsigned port = 0;
    if (!number(hex.substr(colon + 1), port, 16))
        return false;
    any = std::all_of(bytes, bytes + digits / 2, [](unsigned char b) { return b == 0; });
    char text[INET6_ADDRSTRLEN] = {};
    if (any)
        out = "*";
    else if (!inet_ntop(v6 ? AF_INET6 : AF_INET, bytes, text, sizeof text))
        return false;
    else
        out = v6 ? std::string("[") + text + "]" : std::string(text);
    out += ':' + std::to_string(port);
    return true;
}

} // namespace

bool parseStatPolicy(std::string_view stat, int &policy)
{
    // Field 41: the 39th word after the name's last ')' (state is field 3).
    size_t pos = stat.rfind(')');
    if (pos == std::string_view::npos)
        return false;
    pos += 1;
    for (int field = 3; field <= 41; ++field) {
        while (pos < stat.size() && stat[pos] == ' ')
            ++pos;
        size_t end = pos;
        while (end < stat.size() && stat[end] != ' ' && stat[end] != '\n')
            ++end;
        if (end == pos)
            return false;
        if (field == 41)
            return number(stat.substr(pos, end - pos), policy);
        pos = end;
    }
    return false;
}

bool parseSmapsPss(std::string_view text, uint64_t &bytes)
{
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        const std::string_view line = text.substr(pos, end == std::string_view::npos ? std::string_view::npos : end - pos);
        if (startsWith(line, "Pss:")) {
            const std::vector<std::string_view> w = words(line.substr(4));
            uint64_t kb = 0;
            if (w.empty() || !number(w[0], kb))
                return false;
            bytes = kb * 1024;
            return true;
        }
        if (end == std::string_view::npos)
            break;
        pos = end + 1;
    }
    return false;
}

bool parseBootTime(std::string_view text, uint64_t &seconds)
{
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        const std::string_view line = text.substr(pos, end == std::string_view::npos ? std::string_view::npos : end - pos);
        if (startsWith(line, "btime ")) {
            const std::vector<std::string_view> w = words(line.substr(6));
            return !w.empty() && number(w[0], seconds);
        }
        if (end == std::string_view::npos)
            break;
        pos = end + 1;
    }
    return false;
}

void parseInetSockets(std::string_view text, bool v6, bool tcp, std::unordered_map<uint64_t, InetSocket> &out)
{
    // "sl local_address rem_address st tx_queue:rx_queue tr:tm->when retrnsmt uid timeout inode ..."
    eachRow(text, [&](std::string_view line) {
        const std::vector<std::string_view> w = words(line);
        uint64_t inode = 0;
        unsigned state = 0;
        if (w.size() < 10 || !number(w[9], inode) || inode == 0 || !number(w[3], state, 16))
            return;
        InetSocket s;
        s.tcp = tcp;
        bool localAny = false, remoteAny = false;
        if (!inetAddress(w[1], v6, s.local, localAny) || !inetAddress(w[2], v6, s.remote, remoteAny))
            return;
        // No peer: a listener, or a UDP socket that sends anywhere ("*:0").
        if (remoteAny && s.remote == "*:0")
            s.remote.clear();
        s.listening = tcp && state == 0x0A;
        out[inode] = std::move(s);
    });
}

void parseUnixSockets(std::string_view text, std::unordered_map<uint64_t, std::string> &out)
{
    // "Num RefCount Protocol Flags Type St Inode Path": the path is the rest of the line, absent for an unnamed socket.
    eachRow(text, [&](std::string_view line) {
        const std::vector<std::string_view> w = words(line);
        uint64_t inode = 0;
        if (w.size() < 7 || !number(w[6], inode) || inode == 0)
            return;
        std::string path;
        if (w.size() > 7) {
            const size_t at = static_cast<size_t>(w[7].data() - line.data());
            path = std::string(line.substr(at));
        }
        out[inode] = sanitizeDisplay(path);
    });
}

std::string unitOfCgroup(std::string_view path)
{
    std::string_view slice;
    size_t end = path.size();
    while (end > 0) {
        const size_t slash = path.rfind('/', end - 1);
        const size_t begin = slash == std::string_view::npos ? 0 : slash + 1;
        const std::string_view part = path.substr(begin, end - begin);
        const auto endsWith = [&](std::string_view suffix) {
            return part.size() > suffix.size() && part.compare(part.size() - suffix.size(), suffix.size(), suffix) == 0;
        };
        if (endsWith(".service") || endsWith(".scope"))
            return sanitizeDisplay(part);
        if (slice.empty() && endsWith(".slice"))
            slice = part;
        if (slash == std::string_view::npos)
            break;
        end = slash;
    }
    return sanitizeDisplay(slice);
}

ProcessInspector::ProcessInspector(std::string procRoot, uint32_t uid, long clockTicks)
    : m_procRoot(std::move(procRoot)), m_uid(uid), m_clockTicks(clockTicks > 0 ? clockTicks : 100)
{
}

bool ProcessInspector::open(int pid, uint64_t start)
{
    m_handle = ProcessHandle::open(m_procRoot, pid, start);
    m_haveTicks = false;
    m_pssTime = -1;
    m_pss = -1;
    if (!m_handle.valid())
        return false;
    uint64_t btime = 0;
    if (m_bootTime < 0 && readAt(AT_FDCWD, (m_procRoot + "/stat").c_str(), m_buf, 1u << 20) && parseBootTime(m_buf, btime))
        m_bootTime = static_cast<double>(btime);
    return true;
}

bool ProcessInspector::readAt(int dir, const char *name, std::string &out, size_t limit)
{
    out.clear();
    const int fd = openat(dir, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    char buf[16384];
    ssize_t n = 0;
    while (out.size() < limit && (n = ::read(fd, buf, std::min(sizeof buf, limit - out.size()))) > 0)
        out.append(buf, static_cast<size_t>(n));
    close(fd);
    return n >= 0 && !out.empty();
}

std::string ProcessInspector::linkAt(int dir, const char *name)
{
    char buf[4096];
    const ssize_t n = readlinkat(dir, name, buf, sizeof buf);
    return n > 0 ? std::string(buf, static_cast<size_t>(n)) : std::string();
}

ProcessDetails ProcessInspector::read(unsigned what, double now, bool forget)
{
    ProcessDetails d;
    const double cpuStart = threadCpuMs();
    const int dir = m_handle.dir();
    StatFields st;
    // Through the descriptor: once the process has ended its directory reads nothing, even when its pid is taken again.
    if (dir < 0 || !readAt(dir, "stat", m_buf, 4096) || !parseStat(m_buf, st, false) || st.pid != m_handle.pid()
        || st.starttime != m_handle.start()) {
        d.cpuMs = threadCpuMs() - cpuStart;
        return d;
    }
    d.alive = true;
    d.comm = sanitizeDisplay(st.comm);
    d.state = st.state;
    d.ppid = st.ppid;
    d.pgrp = st.pgrp;
    d.threads = st.numThreads;
    d.nice = st.nice;
    d.minorFaults = st.minflt;
    d.majorFaults = st.majflt;
    const double ticks = static_cast<double>(m_clockTicks);
    d.userSeconds = static_cast<double>(st.utime) / ticks;
    d.systemSeconds = static_cast<double>(st.stime) / ticks;
    parseStatPolicy(m_buf, d.policy);
    if (m_bootTime >= 0)
        d.started = m_bootTime + static_cast<double>(st.starttime) / ticks;
    // AM20: a share of one logical processor since the last read.
    const uint64_t total = st.utime + st.stime;
    if (m_haveTicks && !forget && now > m_ticksTime && total >= m_ticks)
        d.cpuPercent = static_cast<double>(total - m_ticks) / ((now - m_ticksTime) * ticks) * 100.0;
    m_haveTicks = true;
    m_ticks = total;
    m_ticksTime = now;

    StatusFields status;
    if (readAt(dir, "status", m_buf, 16384) && parseStatus(m_buf, status, true) && status.hasUid) {
        d.uid = status.ruid;
        d.own = status.ruid == m_uid;
        if (status.hasMemory) {
            d.hasMemory = true;
            d.realMemory = status.vmRssKb * 1024;
            d.virtualMemory = status.vmSizeKb * 1024;
            d.sharedMemory = (status.rssFileKb + status.rssShmemKb) * 1024;
            d.privateMemory = status.rssAnonKb * 1024;
            d.swapped = status.vmSwapKb * 1024;
            d.peakMemory = std::max(status.vmHwmKb, status.vmRssKb) * 1024; // AM31: never below Real Memory
        }
    }

    // The parent, by path (its stat: every owner's is readable); a parent younger than the process is a reused pid (AD40).
    if (st.ppid > 0) {
        StatFields parent;
        const std::string path = m_procRoot + '/' + std::to_string(st.ppid) + "/stat";
        if (readAt(AT_FDCWD, path.c_str(), m_buf, 4096) && parseStat(m_buf, parent, false) && parent.pid == st.ppid
            && parent.starttime <= st.starttime) {
            d.hasParent = true;
            d.parentStart = parent.starttime;
            d.parentComm = sanitizeDisplay(parent.comm);
        }
    }

    if (d.own && (what & InspectMemory)) {
        if (m_pssTime < 0 || now - m_pssTime >= kPssSeconds) {
            uint64_t pss = 0;
            m_pss = readAt(dir, "smaps_rollup", m_buf, 16384) && parseSmapsPss(m_buf, pss) ? static_cast<int64_t>(pss) : -1;
            m_pssTime = now;
        }
        d.proportionalMemory = m_pss;
    }

    if (what & InspectStatistics) {
        readThreads(d);
        if (d.own) { // AD25: another owner's io, unit, command line and links are never read
            IoFields io;
            if (readAt(dir, "io", m_buf, 4096) && parseIo(m_buf, io)) {
                d.readCalls = static_cast<int64_t>(io.syscr);
                d.writeCalls = static_cast<int64_t>(io.syscw);
            }
            if (readAt(dir, "cgroup", m_buf, 4096))
                d.unit = unitOfCgroup(parseCgroupV2(m_buf));
            if (readAt(dir, "cmdline", m_buf, 1u << 17))
                d.command = sanitizeDisplay(cmdlineJoined(m_buf));
            d.executable = sanitizeDisplay(linkAt(dir, "exe"));
            d.workingFolder = sanitizeDisplay(linkAt(dir, "cwd"));
        }
    }

    if (d.own && (what & InspectFiles))
        readFiles(d);

    d.cpuMs = threadCpuMs() - cpuStart;
    return d;
}

void ProcessInspector::readThreads(ProcessDetails &d)
{
    // AM58: context switches summed over the threads (status gives the main thread's alone).
    const int fd = openat(m_handle.dir(), "task", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return;
    DIR *tasks = fdopendir(fd);
    if (!tasks) {
        close(fd);
        return;
    }
    std::string name;
    while (const dirent *entry = readdir(tasks)) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9')
            continue;
        name.assign(entry->d_name).append("/status");
        StatusFields s;
        if (readAt(dirfd(tasks), name.c_str(), m_buf, 16384) && parseStatus(m_buf, s, true) && s.hasCtx) {
            d.hasSwitches = true;
            d.voluntarySwitches += s.voluntaryCtx;
            d.involuntarySwitches += s.involuntaryCtx;
        }
    }
    closedir(tasks);
}

void ProcessInspector::readFiles(ProcessDetails &d)
{
    const int fd = openat(m_handle.dir(), "fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return; // a process that is not dumpable refuses its descriptors even to its owner: "—"
    DIR *list = fdopendir(fd);
    if (!list) {
        close(fd);
        return;
    }
    std::vector<int> fds;
    while (const dirent *entry = readdir(list)) {
        int n = 0;
        if (number(std::string_view(entry->d_name), n) && n >= 0)
            fds.push_back(n);
    }
    std::sort(fds.begin(), fds.end());
    d.hasFiles = true;
    const size_t listed = std::min(fds.size(), kMaxDescriptors);
    d.moreFiles = fds.size() - listed;
    bool socketsRead = false;
    std::unordered_map<uint64_t, InetSocket> inet;
    std::unordered_map<uint64_t, std::string> local;
    for (size_t i = 0; i < listed; ++i) {
        const std::string target = linkAt(dirfd(list), std::to_string(fds[i]).c_str());
        if (target.empty())
            continue; // closed meanwhile
        Descriptor f;
        f.fd = fds[i];
        if (target[0] == '/') {
            f.kind = Descriptor::Kind::File;
            f.name = sanitizeDisplay(target);
        } else if (startsWith(target, "pipe:[")) {
            f.kind = Descriptor::Kind::Pipe;
        } else if (startsWith(target, "socket:[")) {
            // The sockets of the process's own network namespace, read once per read and only when it has one.
            if (!socketsRead) {
                socketsRead = true;
                const struct {
                    const char *file;
                    bool v6, tcp;
                } tables[] = {{"net/tcp", false, true}, {"net/tcp6", true, true}, {"net/udp", false, false}, {"net/udp6", true, false}};
                for (const auto &t : tables) {
                    if (readAt(m_handle.dir(), t.file, m_buf, 8u << 20))
                        parseInetSockets(m_buf, t.v6, t.tcp, inet);
                }
                if (readAt(m_handle.dir(), "net/unix", m_buf, 8u << 20))
                    parseUnixSockets(m_buf, local);
            }
            uint64_t inode = 0;
            number(std::string_view(target).substr(8), inode);
            if (const auto it = inet.find(inode); it != inet.end()) {
                f.kind = it->second.tcp ? Descriptor::Kind::Tcp : Descriptor::Kind::Udp;
                f.local = it->second.local;
                f.remote = it->second.remote;
                f.listening = it->second.listening;
            } else if (const auto at = local.find(inode); at != local.end()) {
                f.kind = Descriptor::Kind::Local;
                f.name = at->second;
            } else {
                f.name = sanitizeDisplay(target);
            }
        } else {
            f.name = sanitizeDisplay(target);
        }
        d.files.push_back(std::move(f));
    }
    closedir(list);
}

} // namespace activity
