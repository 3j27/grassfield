#include "procparse.h"

#include <algorithm>
#include <charconv>
#include <cstdlib>
#include <cstring>
#include <type_traits>

namespace activity
{
namespace
{

// The next line of `text` from `pos` (without its newline); `pos` moves past it. False at the end.
bool nextLine(std::string_view text, size_t &pos, std::string_view &line)
{
    if (pos >= text.size())
        return false;
    const size_t end = text.find('\n', pos);
    if (end == std::string_view::npos) {
        line = text.substr(pos);
        pos = text.size();
    } else {
        line = text.substr(pos, end - pos);
        pos = end + 1;
    }
    return true;
}

std::string_view trim(std::string_view s)
{
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t'))
        ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r'))
        --b;
    return s.substr(a, b - a);
}

// The next space-separated word of `s` from `pos`.
bool nextWord(std::string_view s, size_t &pos, std::string_view &word)
{
    while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t'))
        ++pos;
    if (pos >= s.size())
        return false;
    const size_t start = pos;
    while (pos < s.size() && s[pos] != ' ' && s[pos] != '\t')
        ++pos;
    word = s.substr(start, pos - start);
    return true;
}

template <typename T>
bool toNumber(std::string_view s, T &out)
{
    const auto r = std::from_chars(s.data(), s.data() + s.size(), out);
    return r.ec == std::errc() && r.ptr == s.data() + s.size();
}

bool toDouble(std::string_view s, double &out)
{
    // from_chars for double is not in every libstdc++ the project builds with; the field is short and ASCII.
    std::string tmp(s);
    char *end = nullptr;
    out = std::strtod(tmp.c_str(), &end);
    return end && *end == '\0' && !tmp.empty();
}

// "Key:   1234 kB" → key "Key", value 1234 (the unit is not checked: /proc writes kB for every size field it has).
bool keyValue(std::string_view line, std::string_view &key, std::string_view &value)
{
    const size_t colon = line.find(':');
    if (colon == std::string_view::npos)
        return false;
    key = line.substr(0, colon);
    value = trim(line.substr(colon + 1));
    return true;
}

uint64_t firstNumber(std::string_view value)
{
    size_t pos = 0;
    std::string_view w;
    uint64_t n = 0;
    if (nextWord(value, pos, w))
        toNumber(w, n);
    return n;
}

// One decimal field of a stat line at `p` ('-' first for a signed type), up to the next space or newline; `p` moves past
// the field whatever it holds. False when it is not a number.
template <typename T>
bool statNumber(const char *&p, const char *end, T &out)
{
    bool negative = false;
    if (p < end && *p == '-') {
        negative = true;
        ++p;
    }
    const char *start = p;
    uint64_t v = 0;
    while (p < end && static_cast<unsigned char>(*p - '0') < 10) {
        v = v * 10 + static_cast<unsigned>(*p - '0');
        ++p;
    }
    const bool digitsOnly = p != start && (p == end || *p == ' ' || *p == '\n');
    while (p < end && *p != ' ' && *p != '\n')
        ++p;
    if (!digitsOnly || (negative && !std::is_signed_v<T>))
        return false;
    out = negative ? static_cast<T>(-static_cast<int64_t>(v)) : static_cast<T>(v);
    return true;
}

} // namespace

bool parseStat(std::string_view text, StatFields &out, bool codeAddresses)
{
    const size_t open = text.find('(');
    if (open == std::string_view::npos)
        return false;
    // The name ends at the line's last ')': what follows is numbers and a state letter, so that ')' lies within the name's
    // 64 bytes at most (a workqueue thread's name passes 15). Looked for there first, in the whole line otherwise.
    size_t close = text.substr(0, std::min(text.size(), open + 66)).rfind(')');
    if (close == std::string_view::npos)
        close = text.rfind(')');
    if (close == std::string_view::npos || close < open)
        return false;
    if (!toNumber(trim(text.substr(0, open)), out.pid))
        return false;
    out.comm.assign(text.data() + open + 1, close - open - 1);
    // Fields from 3 on, after the closing parenthesis; field n is word n-3 of the rest. One pass, nothing allocated: every
    // process's stat is parsed at every sample (AM-P2, review of 949fc98).
    const char *p = text.data() + close + 1;
    const char *const end = text.data() + text.size();
    bool ok = true;
    int i = 0;
    const int fields = codeAddresses ? 25 : 22;
    for (; i < fields; ++i) {
        while (p < end && *p == ' ')
            ++p;
        if (p >= end || *p == '\n')
            break;
        switch (i) { // the fields the sampler uses, read as they pass; the others skipped byte by byte
        case 0:
            out.state = *p;
            while (p < end && *p != ' ' && *p != '\n')
                ++p;
            break;
        case 1: ok = statNumber(p, end, out.ppid) && ok; break;
        case 2: ok = statNumber(p, end, out.pgrp) && ok; break;
        case 6: ok = statNumber(p, end, out.flags) && ok; break;
        case 7: ok = statNumber(p, end, out.minflt) && ok; break;
        case 9: ok = statNumber(p, end, out.majflt) && ok; break;
        case 11: ok = statNumber(p, end, out.utime) && ok; break;
        case 12: ok = statNumber(p, end, out.stime) && ok; break;
        case 16: ok = statNumber(p, end, out.nice) && ok; break;
        case 17: ok = statNumber(p, end, out.numThreads) && ok; break;
        case 19: ok = statNumber(p, end, out.starttime) && ok; break;
        case 20: ok = statNumber(p, end, out.vsize) && ok; break;
        case 21: ok = statNumber(p, end, out.rssPages) && ok; break;
        case 23: statNumber(p, end, out.startCode); break; // fields 26 and 27: 0 where the reader may not trace the process
        case 24: statNumber(p, end, out.endCode); break;
        default:
            while (p < end && *p != ' ' && *p != '\n')
                ++p;
            break;
        }
    }
    return ok && i >= 22;
}

namespace
{

void statusField(std::string_view key, std::string_view value, StatusFields &out)
{
    // By length first: most of status's sixty lines are none of these, and are passed over at one comparison.
    switch (key.size()) {
    case 3:
        if (key == "Uid") {
            size_t p = 0;
            std::string_view a, b;
            if (nextWord(value, p, a) && nextWord(value, p, b) && toNumber(a, out.ruid) && toNumber(b, out.euid))
                out.hasUid = true;
        }
        break;
    case 4:
        if (key == "Name")
            out.name = std::string(trim(value));
        else if (key == "PPid")
            toNumber(trim(value), out.ppid);
        break;
    case 5:
        if (key == "VmRSS") {
            out.vmRssKb = firstNumber(value);
            out.hasMemory = true;
        } else if (key == "VmHWM") {
            out.vmHwmKb = firstNumber(value);
        }
        break;
    case 6:
        if (key == "VmSize")
            out.vmSizeKb = firstNumber(value);
        else if (key == "VmSwap")
            out.vmSwapKb = firstNumber(value);
        break;
    case 7:
        if (key == "RssAnon")
            out.rssAnonKb = firstNumber(value);
        else if (key == "RssFile")
            out.rssFileKb = firstNumber(value);
        break;
    case 8:
        if (key == "RssShmem")
            out.rssShmemKb = firstNumber(value);
        break;
    case 23:
        if (key == "voluntary_ctxt_switches") {
            out.voluntaryCtx = firstNumber(value);
            out.hasCtx = true;
        }
        break;
    case 26:
        if (key == "nonvoluntary_ctxt_switches")
            out.involuntaryCtx = firstNumber(value);
        break;
    default:
        break;
    }
}

} // namespace

bool parseStatus(std::string_view text, StatusFields &out, bool switches)
{
    const char *p = text.data();
    const char *const end = p + text.size();
    bool any = false;
    while (p < end) {
        const char *nl = static_cast<const char *>(std::memchr(p, '\n', static_cast<size_t>(end - p)));
        const char *lineEnd = nl ? nl : end;
        // Only keys that start with these letters are looked at: most lines are passed over at one comparison.
        const char first = *p;
        if (first == 'N' || first == 'U' || first == 'P' || first == 'V' || first == 'R' || first == 'v' || first == 'n') {
            const char *colon = p;
            while (colon < lineEnd && *colon != ':')
                ++colon;
            if (colon < lineEnd) {
                any = true;
                const std::string_view key(p, static_cast<size_t>(colon - p));
                statusField(key, std::string_view(colon + 1, static_cast<size_t>(lineEnd - colon - 1)), out);
                // VmSwap is the last size field the kernel writes: past it, only the switches are left to read.
                if (!switches && key == "VmSwap")
                    return true;
            }
        } else if (first != '\n') {
            any = true;
        }
        p = nl ? nl + 1 : end;
    }
    return any;
}

bool parseVoluntarySwitches(std::string_view text, uint64_t &out)
{
    // The second line from the end of a status file: looked for from the end.
    constexpr std::string_view key = "\nvoluntary_ctxt_switches:";
    const size_t at = text.rfind(key);
    if (at == std::string_view::npos)
        return false;
    out = firstNumber(text.substr(at + key.size(), 32));
    return true;
}

bool parseStatm(std::string_view text, Statm &out)
{
    const char *p = text.data();
    const char *const end = p + text.size();
    for (uint64_t *field : {&out.size, &out.resident, &out.shared}) {
        while (p < end && *p == ' ')
            ++p;
        if (!statNumber(p, end, *field))
            return false;
    }
    return true;
}

bool parseIo(std::string_view text, IoFields &out)
{
    size_t pos = 0;
    std::string_view line, key, value;
    int seen = 0;
    while (nextLine(text, pos, line)) {
        if (!keyValue(line, key, value))
            continue;
        const uint64_t n = firstNumber(value);
        if (key == "rchar") {
            out.rchar = n;
        } else if (key == "wchar") {
            out.wchar = n;
        } else if (key == "syscr") {
            out.syscr = n;
        } else if (key == "syscw") {
            out.syscw = n;
        } else if (key == "read_bytes") {
            out.readBytes = n;
            ++seen;
        } else if (key == "write_bytes") {
            out.writeBytes = n;
            ++seen;
        } else if (key == "cancelled_write_bytes") {
            out.cancelledWriteBytes = n;
        }
    }
    return seen == 2;
}

std::string parseCgroupV2(std::string_view text)
{
    size_t pos = 0;
    std::string_view line;
    while (nextLine(text, pos, line)) {
        if (line.size() >= 3 && line.substr(0, 3) == "0::")
            return std::string(line.substr(3));
    }
    return {};
}

std::string cmdlineFirstWord(std::string_view raw)
{
    const size_t nul = raw.find('\0');
    return std::string(nul == std::string_view::npos ? raw : raw.substr(0, nul));
}

std::string cmdlineJoined(std::string_view raw)
{
    while (!raw.empty() && raw.back() == '\0')
        raw.remove_suffix(1);
    std::string out(raw);
    for (char &c : out) {
        if (c == '\0')
            c = ' ';
    }
    return out;
}

std::string_view baseName(std::string_view path)
{
    while (path.size() > 1 && path.back() == '/')
        path.remove_suffix(1);
    const size_t slash = path.rfind('/');
    return slash == std::string_view::npos ? path : path.substr(slash + 1);
}

std::string processName(std::string_view argv0, std::string_view comm, std::string_view exePath)
{
    constexpr std::string_view deleted = " (deleted)";
    if (exePath.size() > deleted.size() && exePath.substr(exePath.size() - deleted.size()) == deleted)
        exePath.remove_suffix(deleted.size());
    const std::string_view exe = exePath.empty() ? std::string_view() : baseName(exePath);
    if (!argv0.empty() && argv0.find(' ') == std::string_view::npos) {
        const std::string_view name = baseName(argv0);
        // The stat name is the invoked file's name cut to 15 bytes (TASK_COMM_LEN - 1): a longer argv[0] matches its start.
        const bool matchesComm = !comm.empty()
            && (name == comm || (comm.size() >= 15 && name.size() > comm.size() && name.substr(0, comm.size()) == comm));
        if (!name.empty() && (name == exe || matchesComm))
            return std::string(name);
    }
    return std::string(exe.empty() ? comm : exe);
}

bool parseProcStat(std::string_view text, CpuTimes &total, std::vector<CpuTimes> &perCpu)
{
    perCpu.clear();
    size_t pos = 0;
    std::string_view line;
    bool found = false;
    while (nextLine(text, pos, line)) {
        if (line.size() < 3 || line.substr(0, 3) != "cpu")
            continue;
        size_t p = 0;
        std::string_view name, w;
        nextWord(line, p, name);
        uint64_t v[8] = {};
        int n = 0;
        while (n < 8 && nextWord(line, p, w)) {
            if (!toNumber(w, v[n]))
                break;
            ++n;
        }
        if (n < 4)
            continue;
        CpuTimes t{v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
        if (name == "cpu") {
            total = t;
            found = true;
        } else {
            perCpu.push_back(t);
        }
    }
    return found;
}

int parseLoadavgTasks(std::string_view text)
{
    size_t p = 0;
    std::string_view w;
    for (int i = 0; i < 4; ++i) {
        if (!nextWord(text, p, w))
            return -1;
    }
    const size_t slash = w.find('/');
    int n = -1;
    if (slash == std::string_view::npos || !toNumber(w.substr(slash + 1), n))
        return -1;
    return n;
}

bool parseMeminfo(std::string_view text, Meminfo &out)
{
    size_t pos = 0;
    std::string_view line, key, value;
    bool total = false, available = false;
    while (nextLine(text, pos, line)) {
        if (!keyValue(line, key, value))
            continue;
        const uint64_t n = firstNumber(value);
        if (key == "MemTotal") {
            out.memTotal = n;
            total = true;
        } else if (key == "MemAvailable") {
            out.memAvailable = n;
            available = true;
        } else if (key == "Buffers")
            out.buffers = n;
        else if (key == "Cached")
            out.cached = n;
        else if (key == "Active(file)")
            out.activeFile = n;
        else if (key == "Inactive(file)")
            out.inactiveFile = n;
        else if (key == "SUnreclaim")
            out.sUnreclaim = n;
        else if (key == "KernelStack")
            out.kernelStack = n;
        else if (key == "PageTables")
            out.pageTables = n;
        else if (key == "Unevictable")
            out.unevictable = n;
        else if (key == "Shmem")
            out.shmem = n;
        else if (key == "AnonPages")
            out.anonPages = n;
        else if (key == "SwapTotal")
            out.swapTotal = n;
        else if (key == "SwapFree")
            out.swapFree = n;
        else if (key == "Committed_AS")
            out.committedAs = n;
        else if (key == "CommitLimit")
            out.commitLimit = n;
    }
    out.ok = total && available;
    return out.ok;
}

bool parsePressure(std::string_view text, Pressure &out)
{
    size_t pos = 0;
    std::string_view line;
    bool some = false;
    while (nextLine(text, pos, line)) {
        size_t p = 0;
        std::string_view kind, w;
        if (!nextWord(line, p, kind))
            continue;
        while (nextWord(line, p, w)) {
            if (w.size() > 6 && w.substr(0, 6) == "avg10=") {
                double v = 0;
                if (!toDouble(w.substr(6), v))
                    break;
                if (kind == "some") {
                    out.someAvg10 = v;
                    some = true;
                } else if (kind == "full") {
                    out.fullAvg10 = v;
                }
            }
        }
    }
    out.ok = some;
    return out.ok;
}

bool SwapDevice::zram() const
{
    std::string_view n = baseName(name);
    return n.size() > 4 && n.substr(0, 4) == "zram";
}

std::vector<SwapDevice> parseSwaps(std::string_view text)
{
    std::vector<SwapDevice> out;
    size_t pos = 0;
    std::string_view line;
    bool header = true;
    while (nextLine(text, pos, line)) {
        if (header) { // "Filename Type Size Used Priority"
            header = false;
            continue;
        }
        size_t p = 0;
        std::string_view name, type, size, used;
        if (!nextWord(line, p, name) || !nextWord(line, p, type) || !nextWord(line, p, size) || !nextWord(line, p, used))
            continue;
        SwapDevice d;
        d.name = std::string(name);
        d.type = std::string(type);
        if (toNumber(size, d.sizeKb) && toNumber(used, d.usedKb))
            out.push_back(std::move(d));
    }
    return out;
}

bool parseZramMemUsed(std::string_view text, uint64_t &bytes)
{
    const std::string_view line = trim(text.substr(0, text.find('\n')));
    size_t p = 0;
    std::string_view w;
    for (int i = 0; i < 3; ++i) {
        if (!nextWord(line, p, w))
            return false;
    }
    return toNumber(w, bytes);
}

std::vector<DiskStat> parseDiskstats(std::string_view text)
{
    std::vector<DiskStat> out;
    size_t pos = 0;
    std::string_view line;
    while (nextLine(text, pos, line)) {
        size_t p = 0;
        std::string_view w;
        std::vector<std::string_view> f;
        while (f.size() < 14 && nextWord(line, p, w))
            f.push_back(w);
        if (f.size() < 14)
            continue;
        DiskStat d;
        d.name = std::string(f[2]);
        if (toNumber(f[3], d.reads) && toNumber(f[5], d.sectorsRead) && toNumber(f[6], d.readTicksMs)
            && toNumber(f[7], d.writes) && toNumber(f[9], d.sectorsWritten) && toNumber(f[10], d.writeTicksMs)
            && toNumber(f[12], d.ioTicksMs))
            out.push_back(std::move(d));
    }
    return out;
}

std::vector<NetDev> parseNetDev(std::string_view text)
{
    std::vector<NetDev> out;
    size_t pos = 0;
    std::string_view line;
    while (nextLine(text, pos, line)) {
        const size_t colon = line.find(':');
        if (colon == std::string_view::npos)
            continue; // the two header lines have none before their "|" columns
        NetDev d;
        d.name = std::string(trim(line.substr(0, colon)));
        std::string_view rest = line.substr(colon + 1);
        size_t p = 0;
        std::string_view w;
        uint64_t v[16] = {};
        int n = 0;
        while (n < 16 && nextWord(rest, p, w)) {
            if (!toNumber(w, v[n]))
                break;
            ++n;
        }
        if (n < 10 || d.name.empty())
            continue;
        d.rxBytes = v[0];
        d.rxPackets = v[1];
        d.txBytes = v[8];
        d.txPackets = v[9];
        out.push_back(std::move(d));
    }
    return out;
}

bool parseDrmFdinfo(std::string_view text, DrmClient &out)
{
    size_t pos = 0;
    std::string_view line, key, value;
    std::map<std::string, uint64_t> total;
    while (nextLine(text, pos, line)) {
        if (!keyValue(line, key, value))
            continue;
        if (key == "drm-driver") {
            out.driver = std::string(value);
        } else if (key == "drm-pdev") {
            out.pdev = std::string(value);
        } else if (key == "drm-client-id") {
            toNumber(value, out.clientId);
        } else if (key.size() > 20 && key.substr(0, 20) == "drm-engine-capacity-") {
            out.engineCapacity[std::string(key.substr(20))] = firstNumber(value);
        } else if (key.size() > 11 && key.substr(0, 11) == "drm-engine-") {
            out.engineNs[std::string(key.substr(11))] = firstNumber(value);
        } else if ((key.size() > 11 && key.substr(0, 11) == "drm-memory-") || (key.size() > 10 && key.substr(0, 10) == "drm-total-")) {
            const bool memory = key.substr(0, 11) == "drm-memory-";
            const std::string region(key.substr(memory ? 11 : 10));
            size_t p = 0;
            std::string_view num, unit;
            uint64_t n = 0;
            if (!nextWord(value, p, num) || !toNumber(num, n))
                continue;
            nextWord(value, p, unit);
            const uint64_t scale = unit == "KiB" ? 1024ull : unit == "MiB" ? 1024ull * 1024 : unit == "GiB" ? 1024ull * 1024 * 1024 : 1ull;
            (memory ? out.memoryBytes : total)[region] = n * scale;
        }
    }
    for (const auto &[region, bytes] : total) // drm-total-* where the driver reports no drm-memory-* for that region
        out.memoryBytes.emplace(region, bytes);
    out.ok = !out.driver.empty();
    return out.ok;
}

} // namespace activity
