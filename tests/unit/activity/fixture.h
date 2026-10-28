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

#include <stdlib.h>
#include <unistd.h>

namespace activity_test
{

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
                                unsigned long long code = 0)
    {
        char buf[512];
        std::snprintf(buf, sizeof buf,
                      "%d (%s) %c %d %d %d 0 -1 %lu 10 0 2 0 %lu %lu 0 0 20 %ld %d 0 %llu 104857600 2560 18446744073709551615 %llu %llu 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n",
                      pid, comm.c_str(), state, ppid, pid, pid, flags, utime, stime, nice, threads, start, code,
                      code ? code + 4096 : 0);
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

private:
    std::string root_;
};

} // namespace activity_test
