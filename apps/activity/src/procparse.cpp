#include "procparse.h"

#include <charconv>
#include <cstdlib>

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

} // namespace

bool parseStat(std::string_view text, StatFields &out)
{
    const size_t open = text.find('(');
    const size_t close = text.rfind(')');
    if (open == std::string_view::npos || close == std::string_view::npos || close < open)
        return false;
    if (!toNumber(trim(text.substr(0, open)), out.pid))
        return false;
    out.comm = std::string(text.substr(open + 1, close - open - 1));
    // Fields from 3 on, after the closing parenthesis; field n is index n-3 of the rest.
    std::string_view rest = text.substr(close + 1);
    size_t pos = 0;
    std::string_view w;
    std::vector<std::string_view> f;
    f.reserve(24);
    while (f.size() < 22 && nextWord(rest, pos, w))
        f.push_back(trim(w));
    if (f.size() < 22)
        return false;
    out.state = f[0].empty() ? '?' : f[0][0];
    bool ok = toNumber(f[1], out.ppid) && toNumber(f[2], out.pgrp) && toNumber(f[6], out.flags)
        && toNumber(f[7], out.minflt) && toNumber(f[9], out.majflt) && toNumber(f[11], out.utime)
        && toNumber(f[12], out.stime) && toNumber(f[16], out.nice) && toNumber(f[17], out.numThreads)
        && toNumber(f[19], out.starttime) && toNumber(f[20], out.vsize) && toNumber(f[21], out.rssPages);
    return ok;
}

bool parseStatus(std::string_view text, StatusFields &out)
{
    size_t pos = 0;
    std::string_view line, key, value;
    bool any = false;
    while (nextLine(text, pos, line)) {
        if (!keyValue(line, key, value))
            continue;
        any = true;
        if (key == "Name") {
            out.name = std::string(value);
        } else if (key == "Uid") {
            size_t p = 0;
            std::string_view a, b;
            if (nextWord(value, p, a) && nextWord(value, p, b) && toNumber(a, out.ruid) && toNumber(b, out.euid))
                out.hasUid = true;
        } else if (key == "PPid") {
            toNumber(value, out.ppid);
        } else if (key == "VmSize") {
            out.vmSizeKb = firstNumber(value);
        } else if (key == "VmRSS") {
            out.vmRssKb = firstNumber(value);
            out.hasMemory = true;
        } else if (key == "RssAnon") {
            out.rssAnonKb = firstNumber(value);
        } else if (key == "RssFile") {
            out.rssFileKb = firstNumber(value);
        } else if (key == "RssShmem") {
            out.rssShmemKb = firstNumber(value);
        } else if (key == "VmSwap") {
            out.vmSwapKb = firstNumber(value);
        } else if (key == "VmHWM") {
            out.vmHwmKb = firstNumber(value);
        } else if (key == "voluntary_ctxt_switches") {
            out.voluntaryCtx = firstNumber(value);
            out.hasCtx = true;
        } else if (key == "nonvoluntary_ctxt_switches") {
            out.involuntaryCtx = firstNumber(value);
        }
    }
    return any;
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
