#include "procparse.h"

#include <algorithm>
#include <charconv>
#include <cstdlib>
#include <cstring>
#include <type_traits>
#include <utility>

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

// statNumber on a NUL-terminated text: the field ends at a space, a newline or the NUL, and no byte needs a bound check.
template <typename T>
bool fieldNumber(const char *&p, T &out)
{
    bool negative = false;
    if (*p == '-') {
        negative = true;
        ++p;
    }
    const char *start = p;
    uint64_t v = 0;
    for (unsigned d; (d = static_cast<unsigned>(static_cast<unsigned char>(*p)) - '0') < 10; ++p)
        v = v * 10 + d;
    const bool digitsOnly = p != start && (*p == ' ' || *p == '\n' || *p == '\0');
    while (*p != ' ' && *p != '\n' && *p != '\0')
        ++p;
    if (!digitsOnly || (negative && !std::is_signed_v<T>))
        return false;
    out = negative ? static_cast<T>(-static_cast<int64_t>(v)) : static_cast<T>(v);
    return true;
}

inline void skipField(const char *&p)
{
    while (*p != ' ' && *p != '\n' && *p != '\0')
        ++p;
}

} // namespace

bool parseStat(std::string_view text, StatFields &out, bool codeAddresses)
{
    out.startCode = out.endCode = 0; // read only with codeAddresses; every other field is set when it returns true
    const size_t open = text.find('(');
    if (open == std::string_view::npos)
        return false;
    // The name ends at the line's last ')': what follows is numbers and a state letter, so that ')' lies within the name's
    // 64 bytes at most (a workqueue thread's name passes 15). Looked for there first, in the whole line otherwise.
    const void *last = memrchr(text.data(), ')', std::min(text.size(), open + 66));
    size_t close = last ? static_cast<size_t>(static_cast<const char *>(last) - text.data()) : text.rfind(')');
    if (close == std::string_view::npos || close < open)
        return false;
    if (!toNumber(trim(text.substr(0, open)), out.pid))
        return false;
    out.comm.assign(text.data() + open + 1, close - open - 1);
    // Fields from 3 on, after the closing parenthesis; field n is word n-3 of the rest. One pass, nothing allocated: every
    // process's stat is parsed at every sample (AM-P2, review of 949fc98). The pass runs on a NUL-terminated copy of the
    // rest, so no byte needs a bound check (2b, the Disk tab's cost: this parse was over half its own instructions); the
    // fields read end well within its first 600 bytes.
    char copy[1024];
    const size_t n = std::min(text.size() - close - 1, sizeof copy - 1);
    std::memcpy(copy, text.data() + close + 1, n);
    copy[n] = '\0';
    const char *p = copy;
    bool ok = true;
    int i = 0;
    const int fields = codeAddresses ? 25 : 22;
    for (; i < fields; ++i) {
        while (*p == ' ')
            ++p;
        if (*p == '\0' || *p == '\n')
            break;
        switch (i) { // the fields the sampler uses, read as they pass; the others skipped byte by byte
        case 0:
            out.state = *p;
            skipField(p);
            break;
        case 1: ok = fieldNumber(p, out.ppid) && ok; break;
        case 2: ok = fieldNumber(p, out.pgrp) && ok; break;
        case 6: ok = fieldNumber(p, out.flags) && ok; break;
        case 7: ok = fieldNumber(p, out.minflt) && ok; break;
        case 9: ok = fieldNumber(p, out.majflt) && ok; break;
        case 11: ok = fieldNumber(p, out.utime) && ok; break;
        case 12: ok = fieldNumber(p, out.stime) && ok; break;
        case 16: ok = fieldNumber(p, out.nice) && ok; break;
        case 17: ok = fieldNumber(p, out.numThreads) && ok; break;
        case 19: ok = fieldNumber(p, out.starttime) && ok; break;
        case 20: ok = fieldNumber(p, out.vsize) && ok; break;
        case 21: ok = fieldNumber(p, out.rssPages) && ok; break;
        case 23: fieldNumber(p, out.startCode); break; // fields 26 and 27: 0 where the reader may not trace the process
        case 24: fieldNumber(p, out.endCode); break;
        default: skipField(p); break;
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
    // One pass, the key told by its length: the Disk and Energy tabs read this file of every own process at every sample
    // (review of f68789c). The pass runs on a NUL-terminated copy (the file is about 150 bytes), as parseStat's (2b).
    char copy[512];
    const size_t n = std::min(text.size(), sizeof copy - 1);
    std::memcpy(copy, text.data(), n);
    copy[n] = '\0';
    const char *p = copy;
    unsigned seen = 0; // one bit per byte field: both are needed, each once (mutant R13 of the review of 19f5d4c)
    while (*p != '\0') {
        const char *key = p;
        while (*p != ':' && *p != '\n' && *p != '\0')
            ++p;
        if (*p == ':') {
            const size_t length = static_cast<size_t>(p - key);
            ++p;
            while (*p == ' ' || *p == '\t')
                ++p;
            uint64_t v = 0;
            if (fieldNumber(p, v)) {
                const auto is = [&](const char *name) { return std::memcmp(key, name, length) == 0; };
                switch (length) {
                case 5:
                    if (is("rchar"))
                        out.rchar = v;
                    else if (is("wchar"))
                        out.wchar = v;
                    else if (is("syscr"))
                        out.syscr = v;
                    else if (is("syscw"))
                        out.syscw = v;
                    break;
                case 10:
                    if (is("read_bytes")) {
                        out.readBytes = v;
                        seen |= 1u;
                    }
                    break;
                case 11:
                    if (is("write_bytes")) {
                        out.writeBytes = v;
                        seen |= 2u;
                    }
                    break;
                case 21:
                    if (is("cancelled_write_bytes"))
                        out.cancelledWriteBytes = v;
                    break;
                default:
                    break;
                }
            }
        }
        while (*p != '\n' && *p != '\0')
            ++p;
        if (*p == '\n')
            ++p;
    }
    return seen == 3u;
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
        if (line.size() < 3 || line.substr(0, 3) != "cpu") {
            if (found)
                break; // the cpu lines come first: intr's thousands of counters after them are not looked at
            continue;
        }
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
    // Read at every sample by every tab since 2b: a key is converted only when it is one of these, and the reading stops
    // once each has been seen (VmallocTotal and the huge pages after Committed_AS are not looked at).
    static constexpr std::pair<std::string_view, uint64_t Meminfo::*> keys[] = {
        {"MemTotal", &Meminfo::memTotal},         {"MemAvailable", &Meminfo::memAvailable},
        {"Buffers", &Meminfo::buffers},           {"Cached", &Meminfo::cached},
        {"Active(file)", &Meminfo::activeFile},   {"Inactive(file)", &Meminfo::inactiveFile},
        {"SUnreclaim", &Meminfo::sUnreclaim},     {"KernelStack", &Meminfo::kernelStack},
        {"PageTables", &Meminfo::pageTables},     {"Unevictable", &Meminfo::unevictable},
        {"Shmem", &Meminfo::shmem},               {"AnonPages", &Meminfo::anonPages},
        {"SwapTotal", &Meminfo::swapTotal},       {"SwapFree", &Meminfo::swapFree},
        {"Committed_AS", &Meminfo::committedAs},  {"CommitLimit", &Meminfo::commitLimit},
    };
    constexpr size_t keyCount = sizeof keys / sizeof keys[0];
    size_t pos = 0, seen = 0;
    std::string_view line, key, value;
    bool total = false, available = false;
    while (seen < keyCount && nextLine(text, pos, line)) {
        if (!keyValue(line, key, value))
            continue;
        for (const auto &[name, field] : keys) {
            if (key != name)
                continue;
            out.*field = firstNumber(value);
            total = total || field == &Meminfo::memTotal;
            available = available || field == &Meminfo::memAvailable;
            ++seen;
            break;
        }
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

std::vector<DiskStat> parseDiskstats(std::string_view text, const std::vector<std::string> *only)
{
    std::vector<DiskStat> out;
    size_t pos = 0;
    std::string_view line;
    while (nextLine(text, pos, line)) {
        size_t p = 0;
        std::string_view f[14];
        size_t n = 0;
        while (n < 3 && nextWord(line, p, f[n]))
            ++n;
        if (n < 3 || (only && !std::binary_search(only->begin(), only->end(), f[2])))
            continue; // the name is the third word: a line left out goes no further
        while (n < 14 && nextWord(line, p, f[n]))
            ++n;
        if (n < 14)
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

int parsePciId(std::string_view text)
{
    while (!text.empty() && (text.back() == '\n' || text.back() == ' '))
        text.remove_suffix(1);
    if (text.size() != 6 || text[0] != '0' || (text[1] != 'x' && text[1] != 'X'))
        return -1;
    int value = 0;
    for (char ch : text.substr(2)) {
        const int digit = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
        if (digit < 0)
            return -1;
        value = value * 16 + digit;
    }
    return value;
}

namespace {

// "<4 hex>  <name>" at the start of `line`: its id and name, or -1.
int pciLine(std::string_view line, std::string_view &name)
{
    if (line.size() < 7 || line[4] != ' ' || line[5] != ' ')
        return -1;
    int value = 0;
    for (char ch : line.substr(0, 4)) {
        const int digit = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : -1;
        if (digit < 0)
            return -1;
        value = value * 16 + digit;
    }
    name = line.substr(6);
    while (!name.empty() && (name.back() == '\r' || name.back() == ' '))
        name.remove_suffix(1);
    return value;
}

} // namespace

PciNames lookupPciIds(std::string_view pciIds, int vendor, int device)
{
    PciNames out;
    if (vendor < 0)
        return out;
    bool inVendor = false;
    size_t pos = 0;
    while (pos < pciIds.size()) {
        size_t end = pciIds.find('\n', pos);
        if (end == std::string_view::npos)
            end = pciIds.size();
        const std::string_view line = pciIds.substr(pos, end - pos);
        pos = end + 1;
        if (line.empty() || line[0] == '#')
            continue;
        std::string_view name;
        if (line[0] != '\t') {
            if (inVendor)
                break; // the vendor's devices are over
            if (line[0] == 'C' && line.size() > 1 && line[1] == ' ')
                break; // the device classes, after every vendor
            if (pciLine(line, name) == vendor) {
                out.vendor = std::string(name);
                inVendor = true;
            }
        } else if (inVendor && pciLine(line.substr(1), name) == device) { // a subsystem line's second tab is no id
            out.device = std::string(name);
            break;
        }
    }
    return out;
}

std::string gpuModelName(const PciNames &names)
{
    if (names.device.empty())
        return std::string();
    auto lastBracket = [](std::string_view s) -> std::string_view {
        const size_t close = s.rfind(']');
        const size_t open = close == std::string_view::npos ? close : s.rfind('[', close);
        return open == std::string_view::npos || close <= open + 1 ? std::string_view() : s.substr(open + 1, close - open - 1);
    };
    std::string_view model = lastBracket(names.device);
    if (model.empty())
        model = names.device;
    std::string_view vendor = lastBracket(names.vendor);
    if (!vendor.empty()) {
        vendor = vendor.substr(0, vendor.find('/'));
    } else {
        vendor = names.vendor;
        for (std::string_view suffix : {", Inc.", " Inc.", " Corporation", " Corp.", " Co., Ltd.", " Co., Ltd", " Ltd.", " Limited"}) {
            if (vendor.size() > suffix.size() && vendor.substr(vendor.size() - suffix.size()) == suffix) {
                vendor.remove_suffix(suffix.size());
                break;
            }
        }
    }
    if (vendor.empty() || (model.size() >= vendor.size() && model.substr(0, vendor.size()) == vendor))
        return std::string(model);
    return std::string(vendor) + ' ' + std::string(model);
}

} // namespace activity
