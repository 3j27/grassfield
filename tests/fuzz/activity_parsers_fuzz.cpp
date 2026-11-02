// Mutation fuzzing of Activity Monitor's readers of text another process of the user can write (review of 5bfd4419, NIT 6;
// ADR-0041 step 5's method, as compositor/tests/ParserFuzzTest.cpp): the shell's projection (windows.json), the journal's
// unit records (App History), cpu.stat, /proc/net/wireless, a cache size, a desktop entry's Exec and Name, a unit's name,
// and Inspect's readers (stat's policy, smaps_rollup, btime, the socket tables, a cgroup's unit). Each is fed a corpus of
// valid texts mutated in the tree (byte flips, dictionary tokens, number extremes, invalid UTF-8, slices deleted,
// duplicated or swapped, truncation, growth past the caps, splices) for GF_FUZZ_ITERATIONS rounds (default 2000) from
// GF_FUZZ_SEED (default 1): the same seed gives the same inputs, so a finding reproduces. Properties: no crash (built with
// ASan and UBSan by tests/fuzz/activity_fuzz.sh), a bounded CPU time per call (the thread's own, which a loaded machine
// does not inflate as it does wall-clock time), the same answer when the same text is read
// twice, and each reader's promises on an accepted input (bounds, ranges, pids above 1). No libFuzzer, no dependency.
#include "apphistory.h"
#include "desktopapps.h"
#include "inspect.h"
#include "machine.h"
#include "runtimefiles.h"
#include "units.h"

#include <QCoreApplication>
#include <QDir>
#include <QTemporaryDir>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include <time.h>

using namespace activity;

namespace
{

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ULL + 0x2545F4914F6CDD1DULL) {}
    uint64_t next()
    { // xorshift64*, as tests/fuzz/mutate.py
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 0x2545F4914F6CDD1DULL;
    }
    size_t below(size_t n) { return n == 0 ? 0 : static_cast<size_t>(next() % n); }
};

const std::vector<std::string> kDictionary = {
    "{", "}", "[", "]", "\"", "\\", ":", ",", " ", "\n", "\t", "null", "true", "false", "-0", "0", "1", "-1", "1e999", "NaN",
    "2147483648", "4294967296", "18446744073709551616", "99999999999999999999999", "0.5", "\\u0000", "\\ud800", "\xc0\xaf",
    "\xed\xa0\x80", "\xff", std::string("\0", 1), "\"v\":1", "\"writer\"", "\"pid\"", "\"start\"", "\"windows\"", "\"app\"",
    "\"idleInhibit\"", "\"notResponding\"", "USER_UNIT", "CPU_USAGE_NSEC", "MEMORY_PEAK", "__REALTIME_TIMESTAMP",
    "app-Hyprland-", "-1a2b3c4d.scope", "@0011aabb.service", "\\x2d", "\\x", "usage_usec ", "K", "M", "G", "Exec=", "Name=",
    "Name[fr]=", "[Desktop Entry]", "env ", "A=B ", "wlan0:", "0A", ":0000", "00000000000000000000000000000000:1F90",
    "/user.slice/", ".scope", ".service", ".slice", "Pss:", "btime ", ") S ", "((", "))"};
const std::vector<std::string> kExtremes = {"-0", "0", "1e999", "NaN", "2147483648", "-2147483649", "4294967296",
                                            "18446744073709551616", "99999999999999999999", std::string(64, '9')};

std::string mutate(Rng &r, std::string s, const std::vector<std::string> &corpus, size_t cap)
{
    const size_t ops = 1 + r.below(4);
    for (size_t i = 0; i < ops; ++i) {
        const size_t at = s.empty() ? 0 : r.below(s.size() + 1);
        switch (r.below(9)) {
        case 0:
            if (!s.empty())
                s[r.below(s.size())] ^= static_cast<char>(1u << r.below(8));
            break;
        case 1:
            s.insert(at, kDictionary[r.below(kDictionary.size())]);
            break;
        case 2:
            s.insert(at, kExtremes[r.below(kExtremes.size())]);
            break;
        case 3:
            if (!s.empty())
                s.erase(at < s.size() ? at : s.size() - 1, 1 + r.below(16));
            break;
        case 4:
            if (!s.empty() && at < s.size())
                s.insert(at, s.substr(at, 1 + r.below(32)));
            break;
        case 5:
            if (!s.empty())
                s.resize(r.below(s.size()));
            break;
        case 6:
            s += corpus[r.below(corpus.size())];
            break;
        case 7: { // growth past a cap
            const std::string piece = s.empty() ? std::string("x") : s.substr(0, 1 + r.below(s.size()));
            while (s.size() < cap + 1)
                s += piece;
            break;
        }
        default:
            s.insert(at, 1, static_cast<char>(r.below(256)));
        }
        if (s.size() > 2 * cap + 64)
            s.resize(2 * cap + 64);
    }
    return s;
}

// The calling thread's CPU time, in milliseconds: what a call costs, whatever else the machine runs (the integrator's
// review of the merge of #86: the wall-clock budget failed under load).
double threadCpuMs()
{
    timespec t{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return static_cast<double>(t.tv_sec) * 1e3 + static_cast<double>(t.tv_nsec) / 1e6;
}

// A call's CPU budget: far above any reader's cost (microseconds), far below a quadratic walk of a capped input.
constexpr double kCallBudgetMs = 250;

int failures = 0;
void fail(const char *reader, const std::string &why, uint64_t seed, size_t iteration)
{
    if (++failures <= 20)
        std::printf("FAIL: %s: %s (seed %llu, iteration %zu)\n", reader, why.c_str(), static_cast<unsigned long long>(seed), iteration);
}

using Reader = std::function<std::string(const std::string &input, std::string &broken)>;

void fuzz(const char *name, const std::vector<std::string> &corpus, size_t cap, uint64_t seed, size_t iterations, const Reader &read)
{
    Rng r(seed ^ std::hash<std::string>{}(name)); // a reader's own sequence, the same each run (std::hash of a string is stable)
    const int before = failures;
    for (size_t i = 0; i < iterations; ++i) {
        const std::string input = mutate(r, corpus[r.below(corpus.size())], corpus, cap);
        std::string broken;
        const double t0 = threadCpuMs();
        const std::string first = read(input, broken);
        const double ms = threadCpuMs() - t0;
        if (!broken.empty())
            fail(name, broken, seed, i);
        if (ms > kCallBudgetMs)
            fail(name, "a call took " + std::to_string(ms) + " ms of CPU", seed, i);
        std::string again;
        if (read(input, again) != first)
            fail(name, "two reads of one text differ", seed, i);
    }
    if (failures == before)
        std::printf("PASS: %s, %zu inputs\n", name, iterations);
    else
        std::printf("FAIL: %s, %d failure(s) in %zu inputs\n", name, failures - before, iterations);
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const char *it = std::getenv("GF_FUZZ_ITERATIONS");
    const char *sd = std::getenv("GF_FUZZ_SEED");
    const size_t n = it ? std::strtoul(it, nullptr, 10) : 2000;
    const uint64_t seed = sd ? std::strtoull(sd, nullptr, 10) : 1;

    // A /proc where pid 700 is the projection's live writer.
    QTemporaryDir root;
    const std::string proc = root.path().toStdString() + "/proc";
    QDir().mkpath(QString::fromStdString(proc + "/700"));
    std::ofstream(proc + "/700/stat") << "700 (qs) S 1 700 700 0 -1 4194304 1 0 0 0 1 1 0 0 20 0 4 0 9000 1 1 1\n";

    fuzz("projection", {R"({"v":1,"writer":{"pid":700,"start":9000},"windows":[{"pid":4242,"app":"foot","idleInhibit":false}],"notResponding":[4242]})",
                        R"({"v":1,"writer":{"pid":700,"start":9000},"windows":[],"notResponding":[]})"},
         kProjectionMax, seed, n, [&](const std::string &in, std::string &broken) {
             const Projection p = parseProjection(QByteArray::fromStdString(in), proc);
             if (p.valid && (p.apps.size() > 256 || p.notResponding.size() > 256))
                 broken = "over 256 entries";
             for (auto it2 = p.apps.cbegin(); it2 != p.apps.cend(); ++it2)
                 if (it2.key() <= 1 || it2->size() > 256)
                     broken = "a pid of 1 or below, or a long app id";
             for (int pid : p.notResponding)
                 if (pid <= 1)
                     broken = "a not-responding pid of 1 or below";
             std::string out = p.valid ? "v" : "-";
             for (auto it2 = p.apps.cbegin(); it2 != p.apps.cend(); ++it2)
                 out += std::to_string(it2.key()) + it2->toStdString() + ",";
             return out;
         });
    fuzz("journal records",
         {"{\"__REALTIME_TIMESTAMP\":\"1800000000000000\",\"MESSAGE_ID\":\"ae8f7b866b0347b9af31fe1c80b127c0\",\"USER_UNIT\":"
          "\"app-Hyprland-foot-1a2b3c4d.scope\",\"CPU_USAGE_NSEC\":\"2000000000\",\"MEMORY_PEAK\":\"50000000\"}\n",
          "{\"__REALTIME_TIMESTAMP\":\"1\",\"USER_UNIT\":\"app-Hyprland-org.gnome.Nautilus@0011aabb.service\",\"CPU_USAGE_NSEC\":\"5\"}\n"},
         64 * 1024, seed, n, [](const std::string &in, std::string &broken) {
             std::string out;
             for (const UnitRecord &r : parseUnitRecords(QByteArray::fromStdString(in))) {
                 if (!parseAppUnit(r.unit.toStdString()))
                     broken = "a record of a unit uwsm did not name";
                 if (!r.hasCpu && !r.hasMemory)
                     broken = "a record without a figure";
                 out += r.unit.toStdString() + std::to_string(r.cpuNs) + "/" + std::to_string(r.memoryPeak) + ";";
             }
             return out;
         });
    fuzz("cpu.stat", {"usage_usec 1234\nuser_usec 1000\nsystem_usec 234\n", "user_usec 1\n"}, 4096, seed, n,
         [](const std::string &in, std::string &) {
             quint64 ns = 0;
             const bool ok = parseCpuStatUsage(QByteArray::fromStdString(in), ns);
             return std::to_string(ok) + "/" + std::to_string(ns);
         });
    fuzz("wireless", {"Inter-| sta-|   Quality\n face | tus | link level noise\nwlan0: 0000   58.  -52.  -256 0 0 0 0 47 0\n"}, 4096,
         seed, n, [](const std::string &in, std::string &) { return std::to_string(wirelessSignal(in, "wlan0")); });
    fuzz("cache size", {"48K\n", "12288K", "32M", "512"}, 64, seed, n,
         [](const std::string &in, std::string &) { return std::to_string(parseCacheSize(in)); });
    fuzz("desktop entry", {"[Desktop Entry]\nName=Foot\nName[fr]=Pied\nIcon=foot\nExec=env A=B /usr/bin/foot --server %U\n"},
         64 * 1024, seed, n, [](const std::string &in, std::string &broken) {
             const QString text = QString::fromUtf8(QByteArray::fromStdString(in));
             const QString exec = execBasename(text);
             if (exec.contains(QLatin1Char('/')))
                 broken = "an Exec basename with a slash";
             const DesktopApp a = parseDesktopApp(text, QStringLiteral("fr_FR"));
             if (a.icon.contains(QLatin1Char('/')))
                 broken = "an icon that is a path";
             return (exec + QLatin1Char('|') + a.name + QLatin1Char('|') + a.icon).toStdString();
         });
    fuzz("unit name", {"app-Hyprland-foot-1a2b3c4d.scope", "app-Hyprland-mpv\\x2dplayer@0011aabb.service",
                       "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope"},
         512, seed, n, [](const std::string &in, std::string &) {
             const std::optional<AppUnit> u = parseAppUnit(unitOf(in));
             return (u ? u->desktop + "|" + u->name + "|" + u->suffix : std::string("-")) + std::to_string(efficiencyEligible(in))
                 + std::to_string(isSessionProcess(in)) + unitOfCgroup(in);
         });
    fuzz("stat policy", {"4242 (a (b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 20 0 4 0 9000 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 1 0\n"},
         4096, seed, n, [](const std::string &in, std::string &) {
             int policy = -1;
             const bool ok = parseStatPolicy(in, policy);
             return std::to_string(ok) + "/" + std::to_string(policy);
         });
    fuzz("smaps and btime", {"Rss: 100 kB\nPss: 42 kB\n", "cpu 1 2 3\nbtime 1700000000\n"}, 4096, seed, n,
         [](const std::string &in, std::string &) {
             uint64_t pss = 0, boot = 0;
             const bool a = parseSmapsPss(in, pss), b = parseBootTime(in, boot);
             return std::to_string(a) + std::to_string(pss) + std::to_string(b) + std::to_string(boot);
         });
    fuzz("socket tables",
         {"  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
          "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1\n",
          "Num       RefCount Protocol Flags    Type St Inode Path\n0000000000000000: 00000002 00000000 00010000 0001 01 23456 /run/x\n"},
         64 * 1024, seed, n, [](const std::string &in, std::string &) {
             std::unordered_map<uint64_t, InetSocket> inet;
             std::unordered_map<uint64_t, std::string> local;
             parseInetSockets(in, false, true, inet);
             parseInetSockets(in, true, false, inet);
             parseUnixSockets(in, local);
             return std::to_string(inet.size()) + "/" + std::to_string(local.size());
         });

    std::printf("activity parsers fuzz: %d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
