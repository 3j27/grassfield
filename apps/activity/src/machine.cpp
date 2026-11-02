#include "machine.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>
#include <utility>

namespace activity
{

namespace
{

std::string readText(const std::string &path)
{
    std::ifstream f(path);
    if (!f)
        return {};
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

std::string trimmed(std::string s)
{
    const auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

bool readNumber(const std::string &path, long long &out)
{
    const std::string text = trimmed(readText(path));
    if (text.empty())
        return false;
    char *end = nullptr;
    errno = 0;
    out = std::strtoll(text.c_str(), &end, 10);
    return errno == 0 && end && *end == '\0';
}

// The cpuN directories, by number.
std::vector<int> cpus(const std::string &sysRoot)
{
    std::vector<int> out;
    DIR *d = opendir((sysRoot + "/devices/system/cpu").c_str());
    if (!d)
        return out;
    while (dirent *e = readdir(d)) {
        const std::string name = e->d_name;
        if (name.size() < 4 || name.compare(0, 3, "cpu") != 0 || !std::all_of(name.begin() + 3, name.end(), ::isdigit))
            continue;
        out.push_back(std::atoi(name.c_str() + 3));
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

} // namespace

uint64_t parseCacheSize(std::string_view text)
{
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back())))
        text.remove_suffix(1);
    if (text.empty())
        return 0;
    uint64_t unit = 1;
    const char last = text.back();
    if (last == 'K' || last == 'M' || last == 'G') {
        unit = last == 'K' ? 1024 : last == 'M' ? 1024 * 1024 : 1024ull * 1024 * 1024;
        text.remove_suffix(1);
    }
    if (text.empty() || !std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; }) || text.size() > 12)
        return 0;
    return std::stoull(std::string(text)) * unit;
}

CpuFacts readCpuFacts(const std::string &sysRoot, const std::string &procRoot)
{
    CpuFacts f;
    std::istringstream info(readText(procRoot + "/cpuinfo"));
    for (std::string line; std::getline(info, line);) {
        if (line.compare(0, 10, "model name") == 0) {
            const size_t colon = line.find(':');
            if (colon != std::string::npos)
                f.model = trimmed(line.substr(colon + 1));
            break;
        }
    }
    std::set<long long> packages;
    std::set<std::pair<long long, long long>> cores;
    std::set<std::string> caches; // "<level>|<type>|<shared_cpu_list>"
    const std::string base = sysRoot + "/devices/system/cpu/";
    for (int n : cpus(sysRoot)) {
        const std::string dir = base + "cpu" + std::to_string(n) + "/";
        long long package = 0, core = 0;
        if (!readNumber(dir + "topology/core_id", core))
            continue; // offline or not a processor
        readNumber(dir + "topology/physical_package_id", package);
        ++f.logical;
        packages.insert(package);
        cores.insert({package, core});
        for (int i = 0; i < 16; ++i) {
            const std::string idx = dir + "cache/index" + std::to_string(i) + "/";
            long long level = 0;
            if (!readNumber(idx + "level", level))
                break;
            const std::string type = trimmed(readText(idx + "type"));
            const std::string shared = trimmed(readText(idx + "shared_cpu_list"));
            if (!caches.insert(std::to_string(level) + '|' + type + '|' + shared).second)
                continue;
            const uint64_t size = parseCacheSize(readText(idx + "size"));
            if (level == 1)
                f.l1 += size;
            else if (level == 2)
                f.l2 += size;
            else if (level == 3)
                f.l3 += size;
        }
    }
    f.sockets = static_cast<int>(packages.size());
    f.cores = static_cast<int>(cores.size());
    long long khz = 0;
    if (readNumber(base + "cpu0/cpufreq/base_frequency", khz) && khz > 0)
        f.baseGhz = static_cast<double>(khz) / 1e6;
    return f;
}

double meanCurrentGhz(const std::string &sysRoot)
{
    double sum = 0;
    int count = 0;
    for (int n : cpus(sysRoot)) {
        long long khz = 0;
        if (readNumber(sysRoot + "/devices/system/cpu/cpu" + std::to_string(n) + "/cpufreq/scaling_cur_freq", khz) && khz > 0) {
            sum += static_cast<double>(khz);
            ++count;
        }
    }
    return count > 0 ? sum / count / 1e6 : -1;
}

double readUptime(const std::string &procRoot)
{
    const std::string text = readText(procRoot + "/uptime");
    char *end = nullptr;
    const double up = std::strtod(text.c_str(), &end);
    return end != text.c_str() && up >= 0 ? up : -1;
}

DiskFacts readDiskFacts(const std::string &sysRoot, const std::string &disk)
{
    DiskFacts f;
    if (disk.empty() || disk.find('/') != std::string::npos || disk[0] == '.')
        return f;
    const std::string dir = sysRoot + "/block/" + disk + "/";
    long long sectors = 0, rotational = 0;
    if (readNumber(dir + "size", sectors) && sectors > 0)
        f.capacity = static_cast<uint64_t>(sectors) * 512;
    if (readNumber(dir + "queue/rotational", rotational))
        f.rotational = rotational ? 1 : 0;
    f.model = trimmed(readText(dir + "device/model"));
    return f;
}

std::string netKind(const std::string &sysRoot, const std::string &interface)
{
    if (interface.empty() || interface.find('/') != std::string::npos || interface[0] == '.')
        return {};
    const std::string dir = sysRoot + "/class/net/" + interface + "/";
    DIR *wireless = opendir((dir + "wireless").c_str());
    if (wireless) {
        closedir(wireless);
        return "wifi";
    }
    DIR *bridge = opendir((dir + "bridge").c_str());
    if (bridge) {
        closedir(bridge);
        return {};
    }
    long long type = 0;
    return readNumber(dir + "type", type) && type == 1 ? "ethernet" : std::string();
}

int wirelessSignal(std::string_view text, std::string_view interface)
{
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string_view::npos)
            end = text.size();
        std::string_view line = text.substr(pos, end - pos);
        pos = end + 1;
        while (!line.empty() && line.front() == ' ')
            line.remove_prefix(1);
        if (line.size() <= interface.size() || line.substr(0, interface.size()) != interface || line[interface.size()] != ':')
            continue;
        // "wlan0: 0000   70.  -40.  -256 ...": status, link quality, signal level, noise.
        std::istringstream fields(std::string(line.substr(interface.size() + 1)));
        std::string status, quality, level;
        if (!(fields >> status >> quality >> level))
            return 0;
        if (!level.empty() && level.back() == '.')
            level.pop_back();
        char *stop = nullptr;
        const long dbm = std::strtol(level.c_str(), &stop, 10);
        return stop && *stop == '\0' ? static_cast<int>(dbm) : 0;
    }
    return 0;
}

Addresses interfaceAddresses(const std::string &interface)
{
    Addresses out;
    ifaddrs *list = nullptr;
    if (getifaddrs(&list) != 0)
        return out;
    for (ifaddrs *a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || !a->ifa_name || interface != a->ifa_name)
            continue;
        char text[INET6_ADDRSTRLEN] = {};
        if (a->ifa_addr->sa_family == AF_INET
            && inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in *>(a->ifa_addr)->sin_addr, text, sizeof text))
            out.v4.emplace_back(text);
        else if (a->ifa_addr->sa_family == AF_INET6
                 && inet_ntop(AF_INET6, &reinterpret_cast<sockaddr_in6 *>(a->ifa_addr)->sin6_addr, text, sizeof text))
            out.v6.emplace_back(text);
    }
    freeifaddrs(list);
    return out;
}

} // namespace activity
