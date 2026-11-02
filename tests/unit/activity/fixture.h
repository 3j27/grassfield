// A fake /proc and /sys tree for the activity monitor's sampler tests (docs/specs/activity.md AM79): files written in place
// (the same inode), so the sampler's kept descriptors read the new contents, as they would read the kernel's.
#pragma once

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>

#include <csignal>
#include <stdlib.h>
#include <unistd.h>

namespace activity_test
{

// Every signal takes its default action, unblocked: a disposition the tests inherited (a background job or a container
// started without a terminal ignores SIGHUP and SIGQUIT) must not keep alive a child that a case signals and then waits for.
// The test process does it as it loads, before any case forks (a child that did it itself could get the signal first and
// drop it); a child calls it again first thing.
inline void defaultSignals()
{
    for (int sig = 1; sig < NSIG; ++sig) {
        if (sig != SIGKILL && sig != SIGSTOP)
            std::signal(sig, SIG_DFL);
    }
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, nullptr);
}
inline const bool kSignalsReset = (defaultSignals(), true);

class Fixture
{
public:
    // Under $TMPDIR (else /tmp). A fixture that cannot be made fails its test loudly (an exception gtest reports), never
    // silently (the review of 949fc98: 17 tests failed for no visible reason where /tmp was not writable).
    Fixture()
    {
        const char *tmp = std::getenv("TMPDIR");
        std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/activity-fixture-XXXXXX";
        if (!mkdtemp(tmpl.data()))
            throw std::runtime_error("activity fixture: mkdtemp(" + tmpl + "): " + std::strerror(errno));
        root_ = tmpl;
        std::filesystem::create_directories(proc());
        std::filesystem::create_directories(sys());
    }
    ~Fixture()
    {
        std::error_code ec;
        std::filesystem::remove_all(root_, ec);
    }
    Fixture(const Fixture &) = delete;
    Fixture &operator=(const Fixture &) = delete;

    std::string proc() const { return root_ + "/proc"; }
    std::string sys() const { return root_ + "/sys"; }

    // Writes `text` at `rel` under the root, truncating the same file (no rename: kept descriptors see it).
    void write(const std::string &rel, const std::string &text) const
    {
        const std::filesystem::path p = std::filesystem::path(root_) / rel;
        std::filesystem::create_directories(p.parent_path());
        std::ofstream f(p, std::ios::binary | std::ios::trunc);
        f << text;
        f.close();
        if (!f)
            throw std::runtime_error("activity fixture: cannot write " + p.string());
    }
    void link(const std::string &target, const std::string &rel) const
    {
        const std::filesystem::path p = std::filesystem::path(root_) / rel;
        std::filesystem::create_directories(p.parent_path());
        std::error_code ec;
        std::filesystem::remove(p, ec);
        std::filesystem::create_symlink(target, p);
    }
    void remove(const std::string &rel) const
    {
        std::error_code ec;
        std::filesystem::remove_all(std::filesystem::path(root_) / rel, ec);
    }

    // /proc/<pid>/stat with the fields the sampler reads; every other field 0.
    static std::string statLine(int pid, const std::string &comm, char state, int ppid, unsigned long flags, unsigned long utime,
                                unsigned long stime, int threads, unsigned long long start, long nice = 0,
                                unsigned long long code = 0, unsigned long long codeEnd = 0)
    {
        char buf[512];
        std::snprintf(buf, sizeof buf,
                      "%d (%s) %c %d %d %d 0 -1 %lu 10 0 2 0 %lu %lu 0 0 20 %ld %d 0 %llu 104857600 2560 18446744073709551615 %llu %llu 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n",
                      pid, comm.c_str(), state, ppid, pid, pid, flags, utime, stime, nice, threads, start, code,
                      codeEnd ? codeEnd : code ? code + 4096 : 0);
        return buf;
    }

    static std::string statusText(const std::string &name, unsigned uid, unsigned long anonKb, unsigned long swapKb,
                                  unsigned long voluntary = 0)
    {
        char buf[1024];
        std::snprintf(buf, sizeof buf,
                      "Name:\t%s\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t1\nPid:\t1\nPPid:\t1\nUid:\t%u\t%u\t%u\t%u\n"
                      "Gid:\t%u\t%u\t%u\t%u\nVmPeak:\t  300000 kB\nVmSize:\t  200000 kB\nVmHWM:\t  %lu kB\nVmRSS:\t  %lu kB\n"
                      "RssAnon:\t  %lu kB\nRssFile:\t  4000 kB\nRssShmem:\t  1000 kB\nVmSwap:\t  %lu kB\nThreads:\t1\n"
                      "voluntary_ctxt_switches:\t%lu\nnonvoluntary_ctxt_switches:\t3\n",
                      name.c_str(), uid, uid, uid, uid, uid, uid, uid, uid, anonKb + 6000, anonKb + 5000, anonKb, swapKb, voluntary);
        return buf;
    }

    // One process: stat, status, cmdline, cgroup.
    void process(int pid, const std::string &comm, unsigned uid, unsigned long ticks, unsigned long long start,
                 const std::string &cmdline, const std::string &cgroup, unsigned long flags = 0) const
    {
        const std::string dir = "proc/" + std::to_string(pid);
        write(dir + "/stat", statLine(pid, comm, 'S', 1, flags, ticks, 0, 1, start));
        write(dir + "/status", statusText(comm, uid, 1000, 0));
        write(dir + "/cmdline", cmdline);
        write(dir + "/cgroup", "0::" + cgroup + "\n");
    }

    // A process with every file Inspect reads (AM57, AM58): stat, status, two threads' status, io, cgroup, cmdline,
    // smaps_rollup, the exe and cwd links, seven descriptors (a file, a pipe, a listening TCP socket, an IPv6 TCP
    // connection, a local socket, an eventfd, a socket of no table) and its network namespace's tables.
    void inspectable(int pid, unsigned long long start, unsigned uid, unsigned long utime, int ppid = 1) const
    {
        const std::string dir = "proc/" + std::to_string(pid);
        write(dir + "/stat", statLine(pid, "worker", 'S', ppid, 0, utime, 20, 2, start, -5));
        write(dir + "/status", statusText("worker", uid, 3000, 512, 0));
        write(dir + "/task/" + std::to_string(pid) + "/status", statusText("worker", uid, 3000, 512, 40));
        write(dir + "/task/" + std::to_string(pid + 1) + "/status", statusText("worker:1", uid, 3000, 512, 2));
        write(dir + "/io", "rchar: 1\nwchar: 2\nsyscr: 31\nsyscw: 17\nread_bytes: 5\nwrite_bytes: 6\ncancelled_write_bytes: 0\n");
        write(dir + "/cgroup", "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-foot@1a2b3c4d.service\n");
        write(dir + "/cmdline", std::string("/usr/bin/worker\0--quiet\0", 24));
        write(dir + "/smaps_rollup", "55d0-7ffc ---p 00000000 00:00 0 [rollup]\nRss:  4000 kB\nPss:  2500 kB\nPss_Anon:  2000 kB\n");
        link("/usr/bin/worker", dir + "/exe");
        link("/home/alice/projects", dir + "/cwd");
        link("/home/alice/notes.txt", dir + "/fd/0");
        link("pipe:[5001]", dir + "/fd/1");
        link("socket:[7001]", dir + "/fd/3");
        link("socket:[7002]", dir + "/fd/4");
        link("socket:[7003]", dir + "/fd/5");
        link("anon_inode:[eventfd]", dir + "/fd/10");
        link("socket:[7999]", dir + "/fd/11");
        // Addresses as a little-endian kernel prints them (each 32-bit word as it lies in memory).
        write(dir + "/net/tcp",
              "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
              "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 7001 1 0 100 0 0 10 0\n");
        write(dir + "/net/tcp6",
              "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when "
              "retrnsmt   uid  timeout inode\n"
              "   0: 00000000000000000000000001000000:D431 0000000000000000FFFF00000A00000A:01BB 01 00000000:00000000 "
              "00:00000000 00000000  1000        0 7002 1 0 20 4 30 10 -1\n");
        write(dir + "/net/udp", "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n");
        write(dir + "/net/udp6", "  sl  local_address rem_address   st\n");
        write(dir + "/net/unix", "Num       RefCount Protocol Flags    Type St Inode Path\n"
                                 "0000000000000000: 00000002 00000000 00010000 0001 01 7003 /run/user/1000/bus\n");
    }

private:
    std::string root_;
};

} // namespace activity_test
