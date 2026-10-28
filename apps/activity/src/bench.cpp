// activity-sampler-bench: the sampler's cost and output without a window (ADR-0038 step 1; docs/specs/activity.md AM-P2). A
// dev and test tool, never installed. tests/apps/activity_cost.sh drives it.
//
//   activity-sampler-bench measure [--tab cpu|memory|energy|disk|network|all] [--samples N] [--interval-ms MS]
//                                  [--proc-root DIR] [--sys-root DIR]
//       N samples of each tab (101 by default, back to back unless --interval-ms, nothing done between two): the median,
//       95th percentile and maximum CPU time of one sample on the sampler's thread, the mean of its user and kernel parts
//       (getrusage, tick-based), the rows and the reads of the last sample.
//   activity-sampler-bench dump [--tab ...] [--samples N] [--interval-ms MS] [--proc-root DIR] [--sys-root DIR]
//       one line per row of the last sample, tab-separated (tests/integration/activity_owners.sh reads it).
//   activity-sampler-bench spawn N T F    N idle processes of T threads and F extra open descriptors each (waits)
//   activity-sampler-bench tcp K          K loopback TCP connections in one process (waits)
#include "sampler.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace activity;

namespace
{

double msBetween(const timeval &a, const timeval &b)
{
    return static_cast<double>(b.tv_sec - a.tv_sec) * 1e3 + static_cast<double>(b.tv_usec - a.tv_usec) / 1e3;
}

void *idleThread(void *)
{
    for (;;)
        pause();
    return nullptr;
}

int spawn(int n, int threads, int fds)
{
    for (int i = 0; i < n; ++i) {
        if (fork() == 0) {
            for (int k = 0; k < fds; ++k)
                open("/dev/null", O_RDONLY);
            pthread_t t;
            for (int k = 1; k < threads; ++k)
                pthread_create(&t, nullptr, idleThread, nullptr);
            idleThread(nullptr);
        }
    }
    for (;;)
        pause();
}

int tcp(int k)
{
    const int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(srv, reinterpret_cast<sockaddr *>(&a), sizeof a) != 0 || listen(srv, k + 8) != 0)
        return 1;
    socklen_t len = sizeof a;
    getsockname(srv, reinterpret_cast<sockaddr *>(&a), &len);
    char data[4096];
    std::memset(data, 'x', sizeof data);
    for (int i = 0; i < k; ++i) {
        const int c = socket(AF_INET, SOCK_STREAM, 0);
        if (connect(c, reinterpret_cast<sockaddr *>(&a), sizeof a) != 0)
            return 1;
        const int peer = accept(srv, nullptr, nullptr);
        if (write(c, data, sizeof data) < 0 || read(peer, data, sizeof data) < 0)
            return 1;
    }
    for (;;)
        pause();
}

const char *tabName(Tab t)
{
    switch (t) {
    case Tab::Cpu:
        return "cpu";
    case Tab::Memory:
        return "memory";
    case Tab::Energy:
        return "energy";
    case Tab::Disk:
        return "disk";
    case Tab::Network:
        return "network";
    }
    return "?";
}

const char *kindName(Kind k)
{
    switch (k) {
    case Kind::App:
        return "app";
    case Kind::Background:
        return "background";
    case Kind::Session:
        return "session";
    case Kind::System:
        return "system";
    case Kind::OtherUser:
        return "other";
    }
    return "?";
}

bool parseTab(const std::string &s, std::vector<Tab> &tabs)
{
    const Tab all[] = {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network};
    tabs.clear();
    for (Tab t : all) {
        if (s == "all" || s == tabName(t))
            tabs.push_back(t);
    }
    return !tabs.empty();
}

void printDump(const Snapshot &s)
{
    std::printf("pid\town\tuid\tkind\tsession\tname\tcpu\tthreads\tmemory\thasIo\tbytesRead\topenFiles\thasNet\ttcpSent\ttcpReceived\tcommand\n");
    for (const ProcessRow &r : s.rows) {
        std::printf("%d\t%d\t%u\t%s\t%d\t%s\t%.2f\t%d\t%llu\t%d\t%llu\t%d\t%d\t%llu\t%llu\t%s\n", r.pid, r.own ? 1 : 0, r.uid,
                    kindName(r.kind), r.session ? 1 : 0, r.name.c_str(), r.cpuPercent, r.threads,
                    static_cast<unsigned long long>(r.memory), r.hasIo ? 1 : 0, static_cast<unsigned long long>(r.bytesRead),
                    r.openFiles, r.hasNet ? 1 : 0, static_cast<unsigned long long>(r.tcpSent),
                    static_cast<unsigned long long>(r.tcpReceived), r.command.c_str());
    }
    std::printf("kernel\t-\t0\tsystem\t0\tKernel\t%.2f\t%d\n", s.kernel.cpuPercent, s.kernel.threads);
}

} // namespace

int main(int argc, char **argv)
{
    if (argc >= 5 && std::strcmp(argv[1], "spawn") == 0)
        return spawn(std::atoi(argv[2]), std::atoi(argv[3]), std::atoi(argv[4]));
    if (argc >= 3 && std::strcmp(argv[1], "tcp") == 0)
        return tcp(std::atoi(argv[2]));
    if (argc < 2 || (std::strcmp(argv[1], "measure") != 0 && std::strcmp(argv[1], "dump") != 0)) {
        std::fprintf(stderr, "usage: activity-sampler-bench measure|dump [--tab T] [--samples N] [--interval-ms MS] [--proc-root DIR] [--sys-root DIR]\n"
                             "       activity-sampler-bench spawn N T F | tcp K\n");
        return 2;
    }
    const bool dump = std::strcmp(argv[1], "dump") == 0;
    std::vector<Tab> tabs;
    parseTab(dump ? "cpu" : "all", tabs);
    int samples = dump ? 2 : 101;
    int intervalMs = dump ? 200 : 0;
    raiseFileLimit();
    Options opt = defaultOptions();
    for (int i = 2; i < argc; ++i) {
        const std::string a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : nullptr;
        if (a == "--tab" && v && parseTab(v, tabs)) {
            ++i;
        } else if (a == "--samples" && v) {
            samples = std::max(1, std::atoi(v));
            ++i;
        } else if (a == "--interval-ms" && v) {
            intervalMs = std::max(0, std::atoi(v));
            ++i;
        } else if (a == "--proc-root" && v) {
            opt.procRoot = v;
            ++i;
        } else if (a == "--sys-root" && v) {
            opt.sysRoot = v;
            ++i;
        } else {
            std::fprintf(stderr, "activity-sampler-bench: unknown or incomplete argument %s\n", a.c_str());
            return 2;
        }
    }
    for (Tab tab : tabs) {
        Sampler sampler(opt);
        const unsigned reads = readsForTab(tab) | (dump ? ReadStatus | ReadIo | ReadCommand | ReadSockets : 0u);
        std::vector<double> ms;
        double userMs = 0, kernelMs = 0;
        const Snapshot *snap = nullptr;
        for (int i = 0; i < samples; ++i) {
            // Back to back, as probe A10 measures, and nothing between two samples: the snapshot is looked at in place
            // (copying 600 rows between samples would put the next one on cold caches the model never has).
            rusage before{}, after{};
            getrusage(RUSAGE_THREAD, &before);
            snap = &sampler.sample(reads);
            getrusage(RUSAGE_THREAD, &after);
            if (i > 0) { // the first sample opens every kept descriptor and has no rates: it is not the steady cost
                ms.push_back(snap->cpuMs);
                userMs += msBetween(before.ru_utime, after.ru_utime);
                kernelMs += msBetween(before.ru_stime, after.ru_stime);
            }
            if (intervalMs)
                std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));
        }
        const Snapshot last = *snap;
        if (dump) {
            printDump(last);
            continue;
        }
        std::sort(ms.begin(), ms.end());
        const double median = ms.empty() ? last.cpuMs : ms[ms.size() / 2];
        const double p95 = ms.empty() ? last.cpuMs : ms[std::min(ms.size() - 1, ms.size() * 95 / 100)];
        const double max = ms.empty() ? last.cpuMs : ms.back();
        size_t own = 0;
        for (const ProcessRow &r : last.rows)
            own += r.own ? 1 : 0;
        const Counters &c = last.counters;
        const double n = ms.empty() ? 1.0 : static_cast<double>(ms.size());
        std::printf("tab %s: samples %d, median %.3f ms, p95 %.3f ms, max %.3f ms (mean %.3f in user mode, %.3f in the kernel); "
                    "rows %zu (own %zu), kernel threads %d; "
                    "reads: listed %llu stat %llu status %llu io %llu thread-status %llu fd-lists %llu fd-links %llu fdinfo %llu "
                    "sock-dumps %llu system %llu; kept %zu\n",
                    tabName(tab), samples, median, p95, max, userMs / n, kernelMs / n, last.rows.size(), own, last.kernel.threads,
                    static_cast<unsigned long long>(c.listed), static_cast<unsigned long long>(c.statReads),
                    static_cast<unsigned long long>(c.statusReads), static_cast<unsigned long long>(c.ioReads),
                    static_cast<unsigned long long>(c.threadStatusReads), static_cast<unsigned long long>(c.fdListReads),
                    static_cast<unsigned long long>(c.fdLinks), static_cast<unsigned long long>(c.fdinfoReads),
                    static_cast<unsigned long long>(c.sockDumps), static_cast<unsigned long long>(c.systemReads), c.keptFiles);
        std::fflush(stdout);
    }
    return 0;
}
